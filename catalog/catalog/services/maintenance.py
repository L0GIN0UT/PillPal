"""Periodic upkeep of the consensus data (ADR 0014 section 3, retention).

* regions that stopped reporting lose their counts after ``CATALOG_INGEST_MAX_AGE_HOURS``;
* every GTIN that has a decision or a candidate is re-decided, because an official source row can
  appear or be withdrawn by an importer without any ingest.

``run_maintenance_once`` is also what the importers call after a successful run
(``redecide_after_import``) and what ``python -m catalog.admin maintenance`` runs.
"""

from __future__ import annotations

import asyncio

from fastapi import FastAPI
from redis.asyncio import Redis
from redis.exceptions import RedisError
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from catalog.config import Settings
from catalog.observability import get_logger
from catalog.services.decisions import Rules, redecide_everything
from catalog.services.ingest import expire_stale_regions

_log = get_logger("catalog.maintenance")


MAINTENANCE_KEY = "catalog_maintenance"
_PURGE_AUDIT = text(
    "DELETE FROM catalog.admin_audit WHERE at < now() - make_interval(days => :days)"
)
# The claim lasts a bit less than the interval so that the next tick of any worker can take it.
CLAIM_FRACTION = 0.9


async def claim_maintenance(redis: Redis, interval_seconds: int) -> bool:
    """One worker per interval runs the upkeep (``SET NX EX``). An unreachable Redis lets every
    worker run: the work is idempotent and serialized by the global consensus lock."""
    try:
        return bool(
            await redis.set(
                MAINTENANCE_KEY, "1", nx=True, ex=int(interval_seconds * CLAIM_FRACTION)
            )
        )
    except (RedisError, OSError):
        return True


async def purge_audit(session: AsyncSession, retention_days: int) -> int:
    """Delete admin_audit rows older than the retention period; returns how many."""
    result = await session.execute(_PURGE_AUDIT, {"days": retention_days})
    return int(result.rowcount or 0)  # type: ignore[attr-defined]


async def run_maintenance_once(
    sessionmaker: async_sessionmaker[AsyncSession], rules: Rules
) -> tuple[int, int]:
    """Expire stale regions, re-decide, purge old audit rows; returns ``(regions expired,
    decisions written)``."""
    async with sessionmaker.begin() as session:
        expired = await expire_stale_regions(session, rules)
        written = await redecide_everything(session, rules)
        purged = await purge_audit(session, rules.audit_retention_days)
    if purged:
        _log.info("audit_purged", rows=purged)
    return expired, written


async def redecide_after_import(
    sessionmaker: async_sessionmaker[AsyncSession], rules: Rules
) -> None:
    """After a successful import: the run is already committed, so a failure here is logged and
    left to the periodic job instead of failing a run that succeeded."""
    try:
        async with sessionmaker.begin() as session:
            written = await redecide_everything(session, rules)
        _log.info("redecided_after_import", decisions_written=written)
    except Exception as exc:
        _log.error("redecide_after_import_failed", exc_type=type(exc).__name__)


async def maintenance_loop(app: FastAPI) -> None:
    """Background task of the private app; sleeps first so startup never competes with requests."""
    settings: Settings = app.state.settings
    rules = Rules.from_settings(settings)
    while True:
        await asyncio.sleep(settings.maintenance_interval_seconds)
        if not await claim_maintenance(app.state.redis, settings.maintenance_interval_seconds):
            continue  # another worker of the private app does it this interval
        try:
            expired, written = await run_maintenance_once(app.state.sessionmaker, rules)
            _log.info("maintenance_done", regions_expired=expired, decisions_written=written)
        except Exception as exc:
            _log.error("maintenance_failed", exc_type=type(exc).__name__)
