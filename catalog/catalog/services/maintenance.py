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
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from catalog.config import Settings
from catalog.observability import get_logger
from catalog.services.decisions import Rules, redecide_everything
from catalog.services.ingest import expire_stale_regions

_log = get_logger("catalog.maintenance")


async def run_maintenance_once(
    sessionmaker: async_sessionmaker[AsyncSession], rules: Rules
) -> tuple[int, int]:
    """Expire stale regions, then re-decide; returns ``(regions expired, decisions written)``."""
    async with sessionmaker.begin() as session:
        expired = await expire_stale_regions(session, rules)
        written = await redecide_everything(session, rules)
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
        try:
            expired, written = await run_maintenance_once(app.state.sessionmaker, rules)
            _log.info("maintenance_done", regions_expired=expired, decisions_written=written)
        except Exception as exc:
            _log.error("maintenance_failed", exc_type=type(exc).__name__)
