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
from dataclasses import dataclass, field
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
from catalog.importers.batching import RecordBatcher
from catalog.importers.ids import composition_id, substance_id
from catalog.importers.levels import (
    LoadContext,
    load_compositions,
    load_products,
    load_substances,
)
from catalog.importers.search_index import rebuild_entries
from catalog.importers.upsert import WITHDRAWABLE, create_seen_table, withdraw_unseen

DEFAULT_STALE_RUN_MINUTES = 360
# Records written per round trip; bounds the memory of a run, not its result.
RECORD_BATCH_SIZE = 5000


class ImportInProgress(ImporterError):
    """Another run of the same source is still ``running``."""

    code = "import_in_progress"


class UnknownSource(ImporterError):
    code = "unknown_source"


class ImportFailed(ImporterError):
    """An unexpected failure (database, malformed data); the cause is chained, never echoed."""

    code = "import_failed"


@dataclass
class KnownIds:
    """Ids written so far in this run: a later level may refer to them."""

    substances: set[UUID] = field(default_factory=set)
    compositions: set[UUID] = field(default_factory=set)


@dataclass(frozen=True)
class ImportResult:
    run_id: UUID
    counts: dict[str, object]


async def _start_run(
    sessionmaker: async_sessionmaker[AsyncSession],
    source: str,
    run_id: UUID,
    digest: str,
    version: str | None,
    stale_run_minutes: int,
) -> None:
    try:
        async with sessionmaker.begin() as session:
            known = await session.execute(
                text("SELECT 1 FROM catalog.sources WHERE code = :code"), {"code": source}
            )
            if known.first() is None:
                raise UnknownSource
            # A killed process leaves a ``running`` row behind; take over the old ones.
            await session.execute(
                text(
                    "UPDATE catalog.import_runs SET status = 'failed', finished_at = now(), "
                    "error_code = 'stale' WHERE source = :source AND status = 'running' "
                    "AND started_at < now() - make_interval(mins => :minutes)"
                ),
                {"source": source, "minutes": stale_run_minutes},
            )
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


async def _write_batch(ctx: LoadContext, batch: list[Record], known: KnownIds) -> int:
    """Write one batch of one level; returns the search entities it rebuilt."""
    first = batch[0]
    if isinstance(first, SubstanceRecord):
        substances = [r for r in batch if isinstance(r, SubstanceRecord)]
        entries = await load_substances(ctx, substances)
        known.substances.update(substance_id(ctx.source, r.source_key) for r in substances)
        return await rebuild_entries(ctx.session, "substance", entries)
    if isinstance(first, CompositionRecord):
        compositions = [r for r in batch if isinstance(r, CompositionRecord)]
        await load_compositions(ctx, compositions, known.substances)
        known.compositions.update(composition_id(ctx.source, r.source_key) for r in compositions)
        return 0
    products = [r for r in batch if isinstance(r, ProductRecord)]
    entries = await load_products(ctx, products, known.compositions)
    return await rebuild_entries(ctx.session, "product", entries)


async def _load(
    session: AsyncSession,
    importer: Importer,
    snapshot_dir: Path,
    run_id: UUID,
    withdraw_missing: bool,
) -> dict[str, Any]:
    source = importer.source
    ctx = LoadContext(session=session, source=source, run_id=run_id)
    await create_seen_table(session)
    # The parser runs in a worker thread one batch at a time: parsing is CPU-heavy and lazy.
    batcher = RecordBatcher(importer.parse(snapshot_dir), RECORD_BATCH_SIZE)
    known = KnownIds()
    rebuilt = 0
    while batch := await asyncio.to_thread(batcher.next_batch):
        rebuilt += await _write_batch(ctx, batch, known)

    if withdraw_missing:
        for kind, table, *_ in WITHDRAWABLE:
            ctx.kind(table).withdrawn = await withdraw_unseen(session, source, run_id, kind)

    counts: dict[str, Any] = {name: c.as_dict() for name, c in ctx.counts.items()}
    counts.update(ctx.extra)
    counts["search_entities_rebuilt"] = rebuilt
    counts.setdefault("gtins_skipped", 0)
    counts.setdefault("products_unlinked", 0)
    skipped = getattr(importer, "skipped", None)
    if skipped:
        counts["parse_skipped"] = dict(skipped)
    return counts


def _code_of(exc: BaseException) -> str:
    return ImportFailed.code if isinstance(exc, Exception) else "import_aborted"


async def _mark_failed(
    sessionmaker: async_sessionmaker[AsyncSession], run_id: UUID, code: str
) -> None:
    try:
        async with sessionmaker.begin() as session:
            await _finish_run(session, run_id, "failed", {}, code)
    except Exception:
        return  # the original error is the one to report


async def run_import(
    sessionmaker: async_sessionmaker[AsyncSession],
    importer: Importer,
    snapshot_dir: Path,
    *,
    withdraw_missing: bool = True,
    stale_run_minutes: int = DEFAULT_STALE_RUN_MINUTES,
) -> ImportResult:
    """Load a snapshot directory with ``importer``. Raises ``ImporterError`` subclasses."""
    importer.ensure_enabled()
    if not await asyncio.to_thread(snapshot_dir.is_dir):
        raise ImporterError("snapshot_not_found")
    digest = await asyncio.to_thread(snapshot_sha256, snapshot_dir)
    version = importer.snapshot_version(snapshot_dir)
    run_id = uuid.uuid4()
    await _start_run(sessionmaker, importer.source, run_id, digest, version, stale_run_minutes)
    try:
        async with sessionmaker.begin() as session:
            counts = await _load(session, importer, snapshot_dir, run_id, withdraw_missing)
            await _finish_run(session, run_id, "succeeded", counts, None)
    except BaseException as exc:
        # Cancellation and interrupts included: a run never stays ``running``.
        code = exc.code if isinstance(exc, ImporterError) else _code_of(exc)
        await _mark_failed(sessionmaker, run_id, code)
        if isinstance(exc, ImporterError) or not isinstance(exc, Exception):
            raise
        raise ImportFailed from None
    return ImportResult(run_id=run_id, counts=counts)
