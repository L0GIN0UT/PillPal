"""Ingest of the regions' confirmation snapshots (ADR 0014 section 3).

A snapshot is a sequence of pages sharing a ``generation``. Pages are staged; on the page marked
``complete`` the region's committed rows are replaced by the staged ones in one transaction and
only the GTINs whose ``(product, count)`` rows changed are re-decided. Because each snapshot is
complete, an opt-out, a deletion or an erasure lowers a count without any per-person signal.

Rules:

* a generation below the last committed **or the staging** one is ``409 generation_stale`` (the
  body names the generation to use next); only a newer generation discards an unfinished older
  one, so a stale sender cannot wipe the staging of the current one in a loop;
* the committed generation is a replay and answers ``duplicate``;
* a generation more than ``CATALOG_INGEST_MAX_GENERATION_SKEW_SECONDS`` ahead of the clock is
  ``422`` (one far-future generation would otherwise block every later snapshot of the region);
* a re-sent page replaces that page's rows; the staged row count is checked against
  ``CATALOG_INGEST_MAX_ITEMS`` after every page (replays cannot inflate the staging);
* unknown or withdrawn product ids and restricted numbers are dropped and counted, never failing
  the page.

Lock order: the region's state row first, then the global consensus lock.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from catalog.config import Settings
from catalog.domain.gtin import GtinError, normalize
from catalog.errors import AppError
from catalog.observability import get_logger
from catalog.schemas.ingest import ConfirmationItem, IngestResult, SnapshotPage
from catalog.services.decisions import Rules, lock_consensus, redecide_many

_log = get_logger("catalog.ingest")

Pairs = dict[tuple[str, uuid.UUID], int]
MILLISECONDS = 1000

_ENSURE_STATE = text(
    "INSERT INTO catalog.gtin_ingest_state (region) VALUES (:region) ON CONFLICT DO NOTHING"
)
_LOAD_STATE = text(
    "SELECT committed_generation, staging_generation, staged_pages, "
    "COALESCE(committed_at >= now() - make_interval(hours => :hours), false) AS fresh "
    "FROM catalog.gtin_ingest_state WHERE region = :region FOR UPDATE"
)
_LIVE_PRODUCTS = text(
    "SELECT id FROM catalog.products WHERE id = ANY(:ids) AND withdrawn_at IS NULL"
)
_DROP_PAGE = text(
    "DELETE FROM catalog.gtin_candidate_staging "
    "WHERE region = :region AND generation = :generation AND page = :page"
)
_STAGE = text(
    "INSERT INTO catalog.gtin_candidate_staging (region, generation, page, gtin, product_id, "
    "confirmations) VALUES (:region, :generation, :page, :gtin, :product, :count) "
    "ON CONFLICT (region, generation, gtin, product_id) "
    "DO UPDATE SET confirmations = :count, page = :page"
)
_STAGED_ROWS = text(
    "SELECT count(*) FROM catalog.gtin_candidate_staging "
    "WHERE region = :region AND generation = :generation"
)
_DISCARD_STAGING = text("DELETE FROM catalog.gtin_candidate_staging WHERE region = :region")
# The GTINs whose rows differ between the committed and the staged snapshot of the region.
_CHANGED = text(
    """
SELECT DISTINCT COALESCE(o.gtin, n.gtin) AS gtin
  FROM (SELECT gtin, product_id, confirmations FROM catalog.gtin_link_candidates
         WHERE region = :region) o
  FULL JOIN (SELECT gtin, product_id, confirmations FROM catalog.gtin_candidate_staging
              WHERE region = :region AND generation = :generation) n
    ON o.gtin = n.gtin AND o.product_id = n.product_id
 WHERE o.confirmations IS DISTINCT FROM n.confirmations
"""
)
# Every GTIN of either side: used when the region's earlier counts had already expired.
_EVERY_GTIN = text(
    "SELECT gtin FROM catalog.gtin_link_candidates WHERE region = :region "
    "UNION SELECT gtin FROM catalog.gtin_candidate_staging "
    "WHERE region = :region AND generation = :generation"
)
_DELETE_CANDIDATES = text("DELETE FROM catalog.gtin_link_candidates WHERE region = :region")
_SWAP_IN = text(
    "INSERT INTO catalog.gtin_link_candidates (region, gtin, product_id, confirmations) "
    "SELECT region, gtin, product_id, confirmations FROM catalog.gtin_candidate_staging "
    "WHERE region = :region AND generation = :generation"
)
_MARK_COMMITTED = text(
    "UPDATE catalog.gtin_ingest_state SET committed_generation = :generation, "
    "committed_at = now(), staging_generation = NULL, staged_pages = '{}' WHERE region = :region"
)
_MARK_STAGING = text(
    "UPDATE catalog.gtin_ingest_state SET staging_generation = :generation, "
    "staged_pages = :pages WHERE region = :region"
)
_RESET_STATE = text(
    "UPDATE catalog.gtin_ingest_state SET committed_generation = 0, committed_at = NULL, "
    "staging_generation = NULL, staged_pages = '{}' WHERE region = :region"
)
_REGION_GTINS = text(
    "SELECT DISTINCT gtin FROM catalog.gtin_link_candidates WHERE region = :region"
)
_AUDIT_RESET = text(
    "INSERT INTO catalog.admin_audit (admin_name, action, region) "
    "VALUES (:name, 'ingest_reset', :region)"
)
_STALE_REGIONS = text(
    """
SELECT s.region FROM catalog.gtin_ingest_state s
 WHERE (s.committed_at IS NULL OR s.committed_at < now() - make_interval(hours => :hours))
   AND EXISTS (SELECT 1 FROM catalog.gtin_link_candidates c WHERE c.region = s.region)
"""
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


def _stale(committed: int, staging: int | None) -> AppError:
    return AppError(
        409,
        "generation_stale",
        "A newer snapshot was already received",
        extra={
            "committed_generation": committed,
            "min_generation": max(committed, staging or 0) + 1,
        },
    )


async def _commit(
    session: AsyncSession, region: str, generation: int, rules: Rules, *, was_fresh: bool
) -> None:
    params = {"region": region, "generation": generation}
    await lock_consensus(session)
    query = _CHANGED if was_fresh else _EVERY_GTIN
    changed = [row.gtin for row in await session.execute(query, params)]
    await session.execute(_DELETE_CANDIDATES, params)
    await session.execute(_SWAP_IN, params)
    await session.execute(_DISCARD_STAGING, params)
    await session.execute(_MARK_COMMITTED, params)
    await redecide_many(session, changed, rules)


async def ingest_page(
    session: AsyncSession, settings: Settings, region: str, body: SnapshotPage, now: datetime
) -> IngestResult:
    """Apply one page inside the caller's transaction (an error rolls the page back)."""
    if region not in settings.accepted_regions:
        raise AppError(403, "forbidden", "This region is not accepted here")
    if len(body.items) > settings.ingest_page_max_items:
        raise AppError(413, "payload_too_large", "Payload too large")
    latest = now + timedelta(seconds=settings.ingest_max_generation_skew_seconds)
    if body.generation > int(latest.timestamp() * MILLISECONDS):
        raise AppError(422, "generation_in_future", "The generation is ahead of the clock")
    rules = Rules.from_settings(settings)
    await session.execute(_ENSURE_STATE, {"region": region})
    state = (
        await session.execute(_LOAD_STATE, {"region": region, "hours": rules.max_age_hours})
    ).one()
    if body.generation < state.committed_generation or (
        state.staging_generation is not None and body.generation < state.staging_generation
    ):
        raise _stale(state.committed_generation, state.staging_generation)
    if body.generation == state.committed_generation:
        return IngestResult(status="duplicate", dropped=0)
    pages: set[int] = set(state.staged_pages)
    if state.staging_generation != body.generation:
        await session.execute(_DISCARD_STAGING, {"region": region})  # only a newer one discards
        pages = set()
    key = {"region": region, "generation": body.generation}
    usable, dropped = await _usable(session, body.items)
    await session.execute(_DROP_PAGE, {**key, "page": body.page})
    if usable:
        rows = [
            {**key, "page": body.page, "gtin": g, "product": p, "count": n}
            for (g, p), n in usable.items()
        ]
        await session.execute(_STAGE, rows)
    staged = (await session.execute(_STAGED_ROWS, key)).scalar_one()
    if staged > settings.ingest_max_items:
        raise AppError(413, "payload_too_large", "Payload too large")
    pages.add(body.page)
    await session.execute(_MARK_STAGING, {**key, "pages": sorted(pages)})
    if not body.complete:
        return IngestResult(status="staged", dropped=dropped)
    if pages != set(range(body.page + 1)):
        raise AppError(409, "snapshot_incomplete", "A page of the snapshot is missing")
    await _commit(session, region, body.generation, rules, was_fresh=state.fresh)
    _log.info("snapshot_committed", region=region, pages=len(pages), items=staged)
    return IngestResult(status="committed", dropped=dropped)


async def reset_region(session: AsyncSession, region: str, admin_name: str, rules: Rules) -> None:
    """Forget a region's ingest state and counts (a poisoned generation, a decommissioned
    region); audited. The region starts again from generation 1; its GTINs are re-decided."""
    await session.execute(_ENSURE_STATE, {"region": region})
    await session.execute(_LOAD_STATE, {"region": region, "hours": rules.max_age_hours})
    await lock_consensus(session)
    gtins = [row.gtin for row in await session.execute(_REGION_GTINS, {"region": region})]
    await session.execute(_DELETE_CANDIDATES, {"region": region})
    await session.execute(_DISCARD_STAGING, {"region": region})
    await session.execute(_RESET_STATE, {"region": region})
    await redecide_many(session, gtins, rules)
    await session.execute(_AUDIT_RESET, {"name": admin_name, "region": region})


async def expire_stale_regions(session: AsyncSession, rules: Rules) -> int:
    """Delete the counts of regions that have not reported within the maximum age (retention)
    and re-decide the GTINs they touched. Returns the number of regions expired."""
    await lock_consensus(session)
    stale = await session.execute(_STALE_REGIONS, {"hours": rules.max_age_hours})
    regions = [row.region for row in stale]
    for region in regions:
        gtins = [row.gtin for row in await session.execute(_REGION_GTINS, {"region": region})]
        await session.execute(_DELETE_CANDIDATES, {"region": region})
        await redecide_many(session, gtins, rules)
    return len(regions)
