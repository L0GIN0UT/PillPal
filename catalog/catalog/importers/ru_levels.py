"""Loading of the two record kinds that are not products: recall flags (Roszdravnadzor) and GTIN
links onto ESKLP packages (the manual GRLS export)."""

from __future__ import annotations

from collections.abc import Sequence
from datetime import UTC, datetime
from typing import Any
from uuid import UUID

from sqlalchemy import and_, literal_column, or_, text
from sqlalchemy.dialects.postgresql import insert as pg_insert

from catalog.db import models
from catalog.db.models import table_of
from catalog.importers.base import PackageLinkRecord, RecallRecord
from catalog.importers.levels import LoadContext, load_gtins
from catalog.importers.ru_common import ESKLP_SOURCE
from catalog.importers.upsert import chunks

SUSPENDED = "suspended"
_UNDATED = datetime.min.replace(tzinfo=UTC)


def _rank(record: RecallRecord) -> tuple[bool, datetime, bool]:
    """Newest decision first; an undated one is the oldest; on the same date a final decision
    (withdrawn, substandard, counterfeit) outranks a suspension."""
    dated = record.published_at is not None
    return dated, record.published_at or _UNDATED, record.reason_code != SUSPENDED


_ESKLP_PACKAGES = text(
    "SELECT pr.registration_number, array_agg(pk.id ORDER BY pk.id) "
    "FROM catalog.products pr JOIN catalog.packages pk ON pk.product_id = pr.id "
    "WHERE pr.source = :esklp AND pr.withdrawn_at IS NULL AND pk.withdrawn_at IS NULL "
    "AND pr.registration_number = ANY(:numbers) GROUP BY pr.registration_number"
)


async def load_recall_flags(ctx: LoadContext, records: Sequence[RecallRecord]) -> None:
    """Upsert by ``(registration_number, series, source)``. Flags are never deleted by an
    import: the list is cumulative public data, and a shorter file must not erase a recall.

    The newest decision of a series wins (``_rank``), within a batch and against the stored
    flag: the published file is sorted newest first, so "last one wins" would keep the oldest."""
    unique: dict[tuple[str, str], RecallRecord] = {}
    for record in records:
        key = (record.registration_number, record.series)
        kept = unique.get(key)
        if kept is None or _rank(record) > _rank(kept):
            unique[key] = record
    table = table_of(models.RecallFlag)
    changed = 0
    for batch in chunks(list(unique.values())):
        insert = pg_insert(table)
        excluded = insert.excluded
        statement: Any = insert.on_conflict_do_update(
            index_elements=["registration_number", "series", "source"],
            set_={"reason_code": excluded.reason_code, "published_at": excluded.published_at},
            where=and_(
                or_(
                    table.c.reason_code.is_distinct_from(excluded.reason_code),
                    table.c.published_at.is_distinct_from(excluded.published_at),
                ),
                _not_older(table, excluded),
            ),
        ).returning(literal_column("(xmax = 0)").label("inserted"))
        values = [
            {
                "registration_number": r.registration_number,
                "series": r.series,
                "reason_code": r.reason_code,
                "source": ctx.source,
                "published_at": r.published_at,
            }
            for r in batch
        ]
        result = await ctx.session.execute(statement, values)
        for (inserted,) in result.all():
            changed += 1
            counts = ctx.kind("recall_flags")
            counts.inserted += 1 if inserted else 0
            counts.updated += 0 if inserted else 1
    ctx.kind("recall_flags").unchanged += len(unique) - changed


def _not_older(table: Any, excluded: Any) -> Any:
    """SQL form of ``_rank(new) >= _rank(stored)``: a stored undated flag yields to anything, an
    undated new one never replaces a dated flag (NULL comparisons are false)."""
    return or_(
        table.c.published_at.is_(None),
        excluded.published_at > table.c.published_at,
        and_(
            excluded.published_at == table.c.published_at,
            or_(excluded.reason_code != SUSPENDED, table.c.reason_code == SUSPENDED),
        ),
    )


async def _drop_conflicts(ctx: LoadContext, candidates: dict[str, UUID]) -> int:
    """Remove from ``candidates`` every GTIN that an earlier batch of this run linked to another
    package (and delete the row that batch wrote); returns how many were dropped."""
    dropped: list[str] = []
    for gtin, package in list(candidates.items()):
        known = ctx.link_owners.get(gtin, package)
        ctx.link_owners[gtin] = package if known == package else None
        if ctx.link_owners[gtin] is None:
            dropped.append(gtin)
            del candidates[gtin]
    if dropped:
        await ctx.session.execute(
            text("DELETE FROM catalog.gtins WHERE gtin = ANY(:gtins) AND source = :source"),
            {"gtins": dropped, "source": ctx.source},
        )
    return len(dropped)


def _bump(ctx: LoadContext, name: str, amount: int = 1) -> None:
    key = f"package_links_{name}"
    ctx.extra[key] = ctx.extra.get(key, 0) + amount


async def load_package_links(ctx: LoadContext, records: Sequence[PackageLinkRecord]) -> None:
    """Attach GTINs to the live ESKLP package of a registration number, only when that number
    names exactly one package (several would be a guess). Nothing of ESKLP is changed."""
    numbers = sorted({r.registration_number for r in records})
    found = await ctx.session.execute(_ESKLP_PACKAGES, {"esklp": ESKLP_SOURCE, "numbers": numbers})
    packages: dict[str, list[UUID]] = {number: list(ids) for number, ids in found.all()}
    owners: dict[str, set[UUID]] = {}
    for record in records:
        ids = packages.get(record.registration_number, [])
        if not ids:
            _bump(ctx, "unmatched")
        elif len(ids) > 1:
            _bump(ctx, "ambiguous")
        else:
            _bump(ctx, "matched")
            for gtin in record.gtins:
                owners.setdefault(gtin, set()).add(ids[0])
    unambiguous = {g: next(iter(p)) for g, p in owners.items() if len(p) == 1}
    ambiguous = len(owners) - len(unambiguous)
    ambiguous += await _drop_conflicts(ctx, unambiguous)
    await load_gtins(ctx, unambiguous, ambiguous=ambiguous)
