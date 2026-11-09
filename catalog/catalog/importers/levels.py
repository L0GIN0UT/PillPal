"""Loading of one level of the catalog at a time (substance, composition, product with its
packages and GTINs). Each function writes through ``upsert`` and returns what it needs for the
search entries. Ids come from ``ids.py``; nothing here reads the wall clock."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any
from uuid import UUID

from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from catalog.db import models
from catalog.db.models import table_of
from catalog.domain.identity import IngredientKey, composition_identity_key
from catalog.importers.base import (
    CompositionRecord,
    ImporterDataError,
    IngredientRecord,
    ProductRecord,
    SubstanceRecord,
)
from catalog.importers.ids import composition_id, package_id, product_id, substance_id
from catalog.importers.search_index import entry_language
from catalog.importers.upsert import KindCounts, chunks, mark_seen, upsert

SearchTexts = dict[UUID, tuple[str, set[tuple[str, str]]]]


@dataclass
class LoadContext:
    session: AsyncSession
    source: str
    run_id: UUID
    counts: dict[str, KindCounts] = field(default_factory=dict)
    extra: dict[str, int] = field(default_factory=dict)

    def kind(self, name: str) -> KindCounts:
        return self.counts.setdefault(name, KindCounts())


def _names_of(record: SubstanceRecord) -> set[tuple[str, str]]:
    names = set(record.names)
    if record.name_en:
        names.add(("en", record.name_en))
    if record.name_ru:
        names.add(("ru", record.name_ru))
    return names


async def _replace_names(ctx: LoadContext, wanted: dict[UUID, set[tuple[str, str]]]) -> set[UUID]:
    """Make ``substance_names`` equal ``wanted``; returns the substances that changed."""
    existing: dict[UUID, set[tuple[str, str]]] = {sid: set() for sid in wanted}
    found = await ctx.session.execute(
        select(
            models.SubstanceName.substance_id, models.SubstanceName.lang, models.SubstanceName.name
        ).where(
            models.SubstanceName.substance_id.in_(list(wanted)),
            models.SubstanceName.source == ctx.source,
        )
    )
    for sid, lang, name in found.all():
        existing[sid].add((lang, name))
    changed = {sid for sid, names in wanted.items() if names != existing[sid]}
    if changed:
        await ctx.session.execute(
            text(
                "DELETE FROM catalog.substance_names "
                "WHERE substance_id = ANY(:ids) AND source = :src"
            ),
            {"ids": list(changed), "src": ctx.source},
        )
        rows = [
            {"substance_id": sid, "lang": lang, "name": name, "source": ctx.source}
            for sid in changed
            for lang, name in sorted(wanted[sid])
        ]
        for batch in chunks(rows):
            await ctx.session.execute(table_of(models.SubstanceName).insert(), list(batch))
    return changed


async def load_substances(ctx: LoadContext, records: Sequence[SubstanceRecord]) -> SearchTexts:
    by_id = {substance_id(ctx.source, r.source_key): r for r in records}
    rows = [
        {
            "id": sid,
            "source": ctx.source,
            "source_key": r.source_key,
            "market": r.market,
            "name_en": r.name_en,
            "name_ru": r.name_ru,
        }
        for sid, r in by_id.items()
    ]
    changes = await upsert(
        ctx.session,
        table_of(models.Substance),
        rows,
        conflict=["id"],
        content=["market", "name_en", "name_ru"],
        key="id",
        run_id=ctx.run_id,
        counts=ctx.kind("substances"),
    )
    renamed = await _replace_names(ctx, {sid: _names_of(r) for sid, r in by_id.items()})
    await mark_seen(ctx.session, "substance", (str(sid) for sid in by_id))
    return {sid: (by_id[sid].market, _names_of(by_id[sid])) for sid in changes.changed | renamed}


def check_complete(record: CompositionRecord) -> None:
    """``complete`` is a claim the loader verifies: a form and a strength for every ingredient."""
    if not record.complete:
        return
    unspecified = record.form_code is None or any(
        i.strength_value is None or i.strength_unit is None for i in record.ingredients
    )
    if unspecified or not record.ingredients:
        raise ImporterDataError("incomplete_composition")


async def _existing_ids(session: AsyncSession, table: str, ids: Sequence[UUID]) -> set[UUID]:
    if not ids:
        return set()
    found = await session.execute(
        text(f"SELECT id FROM catalog.{table} WHERE id = ANY(:ids)"),  # noqa: S608
        {"ids": list(ids)},
    )
    return {row[0] for row in found.all()}


def _substance_of(ctx: LoadContext, ingredient: IngredientRecord, shared: set[UUID]) -> UUID:
    """The substance an ingredient points at: its shared (cross-source) one when that row
    exists, else the source-local one."""
    if ingredient.shared_substance is not None:
        candidate = substance_id(*ingredient.shared_substance)
        if candidate in shared:
            return candidate
    return substance_id(ctx.source, ingredient.substance_key)


def _composition_rows(
    ctx: LoadContext, by_id: dict[UUID, CompositionRecord], shared: set[UUID]
) -> tuple[list[dict[str, Any]], dict[UUID, list[dict[str, Any]]]]:
    rows: list[dict[str, Any]] = []
    ingredient_rows: dict[UUID, list[dict[str, Any]]] = {}
    for cid, record in by_id.items():
        # One row per substance; a repeated ingredient in a record is the last one.
        ingredients = {_substance_of(ctx, i, shared): i for i in record.ingredients}
        ingredient_rows[cid] = [
            {
                "composition_id": cid,
                "substance_id": sid,
                "strength_value": i.strength_value,
                "strength_unit": i.strength_unit,
                "per_value": i.per_value,
                "per_unit": i.per_unit,
            }
            for sid, i in ingredients.items()
        ]
        identity = composition_identity_key(
            record.form_code,
            [
                IngredientKey(sid, i.strength_value, i.strength_unit, i.per_value, i.per_unit)
                for sid, i in ingredients.items()
            ],
        )
        rows.append(
            {
                "id": cid,
                "source": ctx.source,
                "source_key": record.source_key,
                "market": record.market,
                "form_code": record.form_code,
                "form_name_en": record.form_name_en,
                "form_name_ru": record.form_name_ru,
                "complete": record.complete,
                "identity_key": identity,
            }
        )
    if len({row["identity_key"] for row in rows}) != len(rows):
        # UNIQUE (source, identity_key): one source describes a composition once.
        raise ImporterDataError("duplicate_composition")
    return rows, ingredient_rows


async def _shared_substances(
    ctx: LoadContext, by_id: dict[UUID, CompositionRecord], known: set[UUID]
) -> set[UUID]:
    """Cross-source substances the records name that exist (in this run or in the database)."""
    named = {
        substance_id(*i.shared_substance)
        for r in by_id.values()
        for i in r.ingredients
        if i.shared_substance is not None
    }
    return (named & known) | await _existing_ids(ctx.session, "substances", list(named - known))


async def _check_substances_exist(
    ctx: LoadContext, by_id: dict[UUID, CompositionRecord], known: set[UUID], shared: set[UUID]
) -> None:
    wanted = {_substance_of(ctx, i, shared) for r in by_id.values() for i in r.ingredients}
    missing = wanted - known
    if missing - await _existing_ids(ctx.session, "substances", list(missing)):
        raise ImporterDataError("unknown_substance")


async def load_compositions(
    ctx: LoadContext, records: Sequence[CompositionRecord], known_substances: set[UUID]
) -> None:
    by_id = {composition_id(ctx.source, r.source_key): r for r in records}
    for record in by_id.values():
        check_complete(record)
    shared = await _shared_substances(ctx, by_id, known_substances)
    await _check_substances_exist(ctx, by_id, known_substances, shared)
    rows, ingredient_rows = _composition_rows(ctx, by_id, shared)
    changes = await upsert(
        ctx.session,
        table_of(models.Composition),
        rows,
        conflict=["id"],
        content=[
            "market",
            "form_code",
            "form_name_en",
            "form_name_ru",
            "complete",
            "identity_key",
        ],
        key="id",
        run_id=ctx.run_id,
        counts=ctx.kind("compositions"),
    )
    if changes.changed:
        await ctx.session.execute(
            text("DELETE FROM catalog.composition_ingredients WHERE composition_id = ANY(:ids)"),
            {"ids": list(changes.changed)},
        )
        flat = [row for cid in changes.changed for row in ingredient_rows[cid]]
        for batch in chunks(flat):
            await ctx.session.execute(table_of(models.CompositionIngredient).insert(), list(batch))
    await mark_seen(ctx.session, "composition", (str(cid) for cid in by_id))


def _candidate_ids(source: str, record: ProductRecord) -> list[UUID]:
    """Composition ids a product may link to, best first."""
    refs = list(record.composition_alternatives)
    if record.composition_key:
        refs.insert(0, (record.composition_source or source, record.composition_key))
    return [composition_id(src, key) for src, key in refs]


async def load_products(
    ctx: LoadContext, records: Sequence[ProductRecord], known_compositions: set[UUID]
) -> SearchTexts:
    by_id = {product_id(ctx.source, r.source_key): r for r in records}
    candidates = {pid: _candidate_ids(ctx.source, r) for pid, r in by_id.items()}
    wanted = {cid for ids in candidates.values() for cid in ids}
    missing = list(wanted - known_compositions)
    resolvable = known_compositions | await _existing_ids(ctx.session, "compositions", missing)

    rows: list[dict[str, Any]] = []
    for pid, record in by_id.items():
        # Linked only to a composition row that exists; a later import re-links.
        cid = next((c for c in candidates[pid] if c in resolvable), None)
        if cid is None and candidates[pid]:
            ctx.extra["products_unlinked"] = ctx.extra.get("products_unlinked", 0) + 1
        rows.append(
            {
                "id": pid,
                "source": ctx.source,
                "source_key": record.source_key,
                "market": record.market,
                "brand_name": record.brand_name,
                "manufacturer": record.manufacturer,
                "country": record.country,
                "composition_id": cid,
                "rx_status": record.rx_status,
                "registration_number": record.registration_number,
            }
        )
    changes = await upsert(
        ctx.session,
        table_of(models.Product),
        rows,
        conflict=["id"],
        content=[
            "market",
            "brand_name",
            "manufacturer",
            "country",
            "composition_id",
            "rx_status",
            "registration_number",
        ],
        key="id",
        run_id=ctx.run_id,
        counts=ctx.kind("products"),
    )
    await mark_seen(ctx.session, "product", (str(pid) for pid in by_id))
    await load_packages(ctx, by_id)
    return {
        pid: (by_id[pid].market, {(entry_language(by_id[pid].brand_name), by_id[pid].brand_name)})
        for pid in changes.changed
    }


async def load_packages(ctx: LoadContext, products: dict[UUID, ProductRecord]) -> None:
    package_rows: dict[UUID, dict[str, Any]] = {}
    gtin_owners: dict[str, set[UUID]] = {}
    for pid, product in products.items():
        for package in product.packages:
            kid = package_id(ctx.source, package.source_key)
            package_rows[kid] = {
                "id": kid,
                "product_id": pid,
                "source": ctx.source,
                "source_key": package.source_key,
                "description": package.description,
                "count": package.count,
                "count_unit": package.count_unit,
            }
            for gtin in package.gtins:
                gtin_owners.setdefault(gtin, set()).add(kid)
    await upsert(
        ctx.session,
        table_of(models.Package),
        list(package_rows.values()),
        conflict=["id"],
        content=["product_id", "description", "count", "count_unit"],
        key="id",
        run_id=ctx.run_id,
        counts=ctx.kind("packages"),
    )
    await mark_seen(ctx.session, "package", (str(kid) for kid in package_rows))
    # A number on two packages of one source is ambiguous: neither is trusted.
    unambiguous = {g: next(iter(k)) for g, k in gtin_owners.items() if len(k) == 1}
    await load_gtins(ctx, unambiguous, ambiguous=len(gtin_owners) - len(unambiguous))


async def load_gtins(ctx: LoadContext, candidates: dict[str, UUID], ambiguous: int = 0) -> None:
    """Only shareable, check-digit-valid numbers are stored; the rest is counted and dropped
    (the table CHECK is the second line of defence, ADR 0013)."""
    found = await ctx.session.execute(
        text(
            "SELECT g FROM unnest(CAST(:gtins AS text[])) AS g "
            "WHERE catalog.gtin_check_digit_ok(g) AND catalog.gtin_is_shareable(g)"
        ),
        {"gtins": list(candidates)},
    )
    valid = {row[0] for row in found.all()}
    skipped = len(candidates) - len(valid) + ambiguous
    ctx.extra["gtins_skipped"] = ctx.extra.get("gtins_skipped", 0) + skipped
    rows = [
        {"gtin": g, "source": ctx.source, "package_id": candidates[g], "origin": "source"}
        for g in sorted(valid)
    ]
    await upsert(
        ctx.session,
        table_of(models.Gtin),
        rows,
        conflict=["gtin", "source"],
        content=["package_id", "origin"],
        key="gtin",
        run_id=ctx.run_id,
        counts=ctx.kind("gtins"),
    )
    await mark_seen(ctx.session, "gtin", valid)
