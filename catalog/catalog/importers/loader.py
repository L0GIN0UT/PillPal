"""The shared loader (docs/phase4-plan.md "Importer design", ADR 0012 section 3).

A run has two transactions on purpose. The first records ``import_runs`` as ``running`` and
commits, so a concurrent run of the same source is refused by the partial unique index. The
second does all the work and marks the run ``succeeded`` in the same commit: a failure rolls the
data back completely and the run is then recorded as ``failed`` in a third short transaction.
"""

from __future__ import annotations

import asyncio
import json
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from catalog.importers.base import (
    CompositionRecord,
    Importer,
    ImporterError,
    ProductRecord,
    Record,
    SubstanceRecord,
    snapshot_sha256,
)
from catalog.importers.ids import composition_id, substance_id
from catalog.importers.levels import (
    LoadContext,
    SearchTexts,
    load_compositions,
    load_products,
    load_substances,
)
from catalog.importers.search_index import rebuild_entries
from catalog.importers.upsert import WITHDRAWABLE, create_seen_table, withdraw_unseen


class ImportInProgress(ImporterError):
    """Another run of the same source is still ``running``."""

    code = "import_in_progress"


class UnknownSource(ImporterError):
    code = "unknown_source"


class ImportFailed(ImporterError):
    """An unexpected failure (database, malformed data); the cause is chained, never echoed."""

    code = "import_failed"


@dataclass(frozen=True)
class ImportResult:
    run_id: UUID
    counts: dict[str, Any]


async def _start_run(
    sessionmaker: async_sessionmaker[AsyncSession],
    source: str,
    run_id: UUID,
    digest: str,
    version: str | None,
) -> None:
    try:
        async with sessionmaker.begin() as session:
            known = await session.execute(
                text("SELECT 1 FROM catalog.sources WHERE code = :code"), {"code": source}
            )
            if known.first() is None:
                raise UnknownSource
            await session.execute(
                text(
                    "INSERT INTO catalog.import_runs (id, source, source_version, snapshot_sha256, "
                    "status) VALUES (:id, :source, :version, :digest, 'running')"
                ),
                {"id": run_id, "source": source, "version": version, "digest": digest},
            )
    except IntegrityError as exc:
        raise ImportInProgress from exc


async def _finish_run(
    session: AsyncSession, run_id: UUID, status: str, counts: dict[str, Any], error: str | None
) -> None:
    await session.execute(
        text(
            "UPDATE catalog.import_runs SET status = :status, finished_at = now(), "
            "counts = CAST(:counts AS jsonb), error_code = :error WHERE id = :id"
        ),
        {
            "id": run_id,
            "status": status,
            "counts": json.dumps(counts, sort_keys=True),
            "error": error,
        },
    )


async def _load(
    session: AsyncSession,
    source: str,
    run_id: UUID,
    records: list[Record],
    withdraw_missing: bool,
) -> dict[str, Any]:
    substances = [r for r in records if isinstance(r, SubstanceRecord)]
    compositions = [r for r in records if isinstance(r, CompositionRecord)]
    products = [r for r in records if isinstance(r, ProductRecord)]
    ctx = LoadContext(session=session, source=source, run_id=run_id)
    await create_seen_table(session)

    substance_entries = await load_substances(ctx, substances)
    known_substances = {substance_id(source, r.source_key) for r in substances}
    await load_compositions(ctx, compositions, known_substances)
    known_compositions = {composition_id(source, r.source_key) for r in compositions}
    product_entries = await load_products(ctx, products, known_compositions)

    if withdraw_missing:
        for kind, table, *_ in WITHDRAWABLE:
            ctx.kind(table).withdrawn = await withdraw_unseen(session, source, run_id, kind)

    rebuilt = await _rebuild(session, substance_entries, product_entries)
    counts: dict[str, Any] = {name: c.as_dict() for name, c in ctx.counts.items()}
    counts.update(ctx.extra)
    counts["search_entities_rebuilt"] = rebuilt
    counts.setdefault("gtins_skipped", 0)
    counts.setdefault("products_unlinked", 0)
    return counts


async def _rebuild(session: AsyncSession, substances: SearchTexts, products: SearchTexts) -> int:
    done = await rebuild_entries(session, "substance", substances)
    return done + await rebuild_entries(session, "product", products)


async def run_import(
    sessionmaker: async_sessionmaker[AsyncSession],
    importer: Importer,
    snapshot_dir: Path,
    *,
    withdraw_missing: bool = True,
) -> ImportResult:
    """Load a snapshot directory with ``importer``. Raises ``ImporterError`` subclasses."""
    importer.ensure_enabled()
    if not await asyncio.to_thread(snapshot_dir.is_dir):
        raise ImporterError("snapshot_not_found")
    digest = await asyncio.to_thread(snapshot_sha256, snapshot_dir)
    version = importer.snapshot_version(snapshot_dir)
    run_id = uuid.uuid4()
    await _start_run(sessionmaker, importer.source, run_id, digest, version)
    try:
        # Parsing is pure and may be CPU-heavy: keep it off the event loop.
        records = await asyncio.to_thread(lambda: list(importer.parse(snapshot_dir)))
        async with sessionmaker.begin() as session:
            counts = await _load(session, importer.source, run_id, records, withdraw_missing)
            await _finish_run(session, run_id, "succeeded", counts, None)
    except Exception as exc:
        code = exc.code if isinstance(exc, ImporterError) else ImportFailed.code
        async with sessionmaker.begin() as session:
            await _finish_run(session, run_id, "failed", {}, code)
        if isinstance(exc, ImporterError):
            raise
        raise ImportFailed from exc
    return ImportResult(run_id=run_id, counts=counts)
