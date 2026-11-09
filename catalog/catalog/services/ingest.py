"""Ingest of the regions' confirmation snapshots (ADR 0014 section 3).

A snapshot is a sequence of pages sharing a ``generation``. Pages are staged; on the page marked
``complete`` the region's committed rows are replaced by the staged ones in one transaction and
every GTIN the old or the new snapshot mentions is re-decided. Because each snapshot is complete,
an opt-out, a deletion or an erasure in the region lowers a count without any per-person signal.

Rules: a generation below the last committed one is refused; the committed one is a replay and
answers ``duplicate``; a newer generation discards an unfinished older one; unknown or withdrawn
product ids and restricted numbers are dropped and counted, never failing the page.
"""

from __future__ import annotations

import uuid

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from catalog.config import Settings
from catalog.domain.consensus import Thresholds
from catalog.domain.gtin import GtinError, normalize
from catalog.errors import AppError
from catalog.observability import get_logger
from catalog.schemas.ingest import ConfirmationItem, IngestResult, SnapshotPage
from catalog.services.decisions import redecide

_log = get_logger("catalog.ingest")

Pairs = dict[tuple[str, uuid.UUID], int]

_ENSURE_STATE = text(
    "INSERT INTO catalog.gtin_ingest_state (region) VALUES (:region) ON CONFLICT DO NOTHING"
)
_LOAD_STATE = text(
    "SELECT committed_generation, staging_generation, staged_pages, staged_items "
    "FROM catalog.gtin_ingest_state WHERE region = :region FOR UPDATE"
)
_LIVE_PRODUCTS = text(
    "SELECT id FROM catalog.products WHERE id = ANY(:ids) AND withdrawn_at IS NULL"
)
_STAGE = text(
    "INSERT INTO catalog.gtin_candidate_staging (region, generation, gtin, product_id, "
    "confirmations) VALUES (:region, :generation, :gtin, :product, :count) "
    "ON CONFLICT (region, generation, gtin, product_id) DO UPDATE SET confirmations = :count"
)
_TOUCHED = text(
    "SELECT gtin FROM catalog.gtin_link_candidates WHERE region = :region "
    "UNION SELECT gtin FROM catalog.gtin_candidate_staging "
    "WHERE region = :region AND generation = :generation"
)
_SWAP_IN = text(
    "INSERT INTO catalog.gtin_link_candidates (region, gtin, product_id, confirmations) "
    "SELECT region, gtin, product_id, confirmations FROM catalog.gtin_candidate_staging "
    "WHERE region = :region AND generation = :generation"
)
_MARK_COMMITTED = text(
    "UPDATE catalog.gtin_ingest_state SET committed_generation = :generation, "
    "committed_at = now(), staging_generation = NULL, staged_pages = '{}', "
    "staged_items = 0 WHERE region = :region"
)
_MARK_STAGING = text(
    "UPDATE catalog.gtin_ingest_state SET staging_generation = :generation, "
    "staged_pages = :pages, staged_items = :items WHERE region = :region"
)


def _shareable(gtin14: str) -> bool:
    try:
        return normalize(gtin14).classification == "shareable"
    except GtinError:
        return False


def _dedupe(items: list[ConfirmationItem]) -> Pairs:
    # The last count of a pair wins; a repeated pair would make one INSERT touch a row twice.
    return {(i.gtin, i.product_id): i.count for i in items}


async def _usable(session: AsyncSession, items: list[ConfirmationItem]) -> tuple[Pairs, int]:
    """The pairs worth staging and how many were dropped (unknown product, restricted number)."""
    pairs = _dedupe(items)
    ids = {product for _, product in pairs}
    live: set[uuid.UUID] = set()
    if ids:
        live = {row.id for row in await session.execute(_LIVE_PRODUCTS, {"ids": list(ids)})}
    usable = {pair: n for pair, n in pairs.items() if pair[1] in live and _shareable(pair[0])}
    return usable, len(pairs) - len(usable)


async def _discard_staging(session: AsyncSession, region: str) -> None:
    await session.execute(
        text("DELETE FROM catalog.gtin_candidate_staging WHERE region = :region"),
        {"region": region},
    )


async def _commit(
    session: AsyncSession, region: str, generation: int, thresholds: Thresholds
) -> None:
    params = {"region": region, "generation": generation}
    gtins = sorted(row.gtin for row in await session.execute(_TOUCHED, params))
    await session.execute(
        text("DELETE FROM catalog.gtin_link_candidates WHERE region = :region"), params
    )
    await session.execute(_SWAP_IN, params)
    await _discard_staging(session, region)
    await session.execute(_MARK_COMMITTED, params)
    # Sorted: concurrent ingests of two regions take the per-GTIN locks in the same order.
    for gtin in gtins:
        await redecide(session, gtin, thresholds)


async def ingest_page(
    session: AsyncSession, settings: Settings, region: str, body: SnapshotPage
) -> IngestResult:
    """Apply one page inside the caller's transaction (an error rolls the page back)."""
    if len(body.items) > settings.ingest_page_max_items:
        raise AppError(413, "payload_too_large", "Payload too large")
    await session.execute(_ENSURE_STATE, {"region": region})
    state = (await session.execute(_LOAD_STATE, {"region": region})).one()
    if body.generation < state.committed_generation:
        raise AppError(409, "generation_stale", "A newer snapshot was already committed")
    if body.generation == state.committed_generation:
        return IngestResult(status="duplicate", dropped=0)
    pages: set[int] = set(state.staged_pages)
    staged_items: int = state.staged_items
    if state.staging_generation != body.generation:
        await _discard_staging(session, region)
        pages, staged_items = set(), 0
    usable, dropped = await _usable(session, body.items)
    if body.page not in pages:
        staged_items += len(usable)
    if staged_items > settings.ingest_max_items:
        raise AppError(413, "payload_too_large", "Payload too large")
    pages.add(body.page)
    if usable:
        rows = [
            {"region": region, "generation": body.generation, "gtin": g, "product": p, "count": n}
            for (g, p), n in usable.items()
        ]
        await session.execute(_STAGE, rows)
    await session.execute(
        _MARK_STAGING,
        {
            "region": region,
            "generation": body.generation,
            "pages": sorted(pages),
            "items": staged_items,
        },
    )
    if not body.complete:
        return IngestResult(status="staged", dropped=dropped)
    if pages != set(range(body.page + 1)):
        raise AppError(409, "snapshot_incomplete", "A page of the snapshot is missing")
    thresholds = Thresholds(settings.consensus_min_confirmations, settings.consensus_dispute_min)
    await _commit(session, region, body.generation, thresholds)
    _log.info("snapshot_committed", region=region, pages=len(pages), items=staged_items)
    return IngestResult(status="committed", dropped=dropped)
