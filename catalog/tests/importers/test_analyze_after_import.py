"""A successful import run refreshes the planner statistics of the tables it wrote.

Regression of the staging incident: after a full ESKLP load the statistics still described an
empty catalog, the planner chose plans for a few rows and nearly every search hit the statement
timeout until someone ran ANALYZE by hand. ``last_analyze`` only moves on a manual ANALYZE
(autovacuum records ``last_autoanalyze``), so it proves that the loader ran it.
"""

from __future__ import annotations

from datetime import datetime

import pytest
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from catalog.importers.base import ImporterError
from catalog.importers.fixture import FixtureImporter, ensure_dev_source
from catalog.importers.loader import ANALYZED_TABLES, run_import
from tests.importers.support import V1, rows

Sessions = async_sessionmaker[AsyncSession]
SEARCH_TABLES = {
    "search_entries",
    "products",
    "packages",
    "gtins",
    "compositions",
    "composition_ingredients",
    "substances",
    "recall_flags",
}


async def _last_analyze(engine: AsyncEngine) -> dict[str, datetime | None]:
    found = await rows(
        engine,
        "SELECT relname, last_analyze FROM pg_stat_user_tables WHERE schemaname = 'catalog'",
    )
    return {str(name): at for name, at in found}


def test_every_table_search_reads_is_analyzed() -> None:
    assert set(ANALYZED_TABLES) >= SEARCH_TABLES


async def test_a_successful_run_analyzes_the_catalog_tables(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    async with sessionmaker.begin() as session:
        await ensure_dev_source(session, "fixture")
    before = await _last_analyze(engine)

    await run_import(sessionmaker, FixtureImporter(), V1)

    after = await _last_analyze(engine)
    for table in ANALYZED_TABLES:
        previous, current = before.get(table), after[table]
        assert current is not None, table
        assert previous is None or current > previous, table


async def test_a_failed_run_does_not_analyze(sessionmaker: Sessions, engine: AsyncEngine) -> None:
    before = await _last_analyze(engine)
    with pytest.raises(ImporterError):
        await run_import(sessionmaker, FixtureImporter(), V1.parent / "missing")
    assert await _last_analyze(engine) == before
