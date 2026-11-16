"""A successful import run refreshes the planner statistics of the tables it wrote.

Regression of the staging incident: after a full ESKLP load the statistics still described an
empty catalog, the planner chose plans for a few rows and nearly every search hit the statement
timeout until someone ran ANALYZE by hand. ``last_analyze`` only moves on a manual ANALYZE
(autovacuum records ``last_autoanalyze``), so it proves that the loader ran it.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from catalog.db.session import create_sessionmaker
from catalog.domain.consensus import Thresholds
from catalog.importers.base import ImporterDataError
from catalog.importers.fixture import FixtureImporter, ensure_dev_source
from catalog.importers.loader import (
    ANALYZED_TABLES,
    DECISION_TABLES,
    AnalyzeFailed,
    run_import,
)
from catalog.services.decisions import Rules
from tests.conftest import TEST_DATABASE_URL
from tests.importers.support import V1, mutated_snapshot, rows

Sessions = async_sessionmaker[AsyncSession]
RULES = Rules(Thresholds(promote_at=3, dispute_at=2), max_age_hours=72)


@pytest_asyncio.fixture(autouse=True)
async def fixture_source(sessionmaker: Sessions) -> None:
    async with sessionmaker.begin() as session:
        await ensure_dev_source(session, "fixture")


async def _last_analyze(engine: AsyncEngine) -> dict[str, datetime | None]:
    found = await rows(
        engine,
        "SELECT relname, last_analyze FROM pg_stat_user_tables WHERE schemaname = 'catalog'",
    )
    return {str(name): at for name, at in found}


async def test_a_successful_run_analyzes_the_catalog_and_decision_tables(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    before = await _last_analyze(engine)

    await run_import(sessionmaker, FixtureImporter(), V1, consensus_rules=RULES)

    after = await _last_analyze(engine)
    for table in ANALYZED_TABLES + DECISION_TABLES:
        previous, current = before.get(table), after[table]
        assert current is not None, table
        assert previous is None or current > previous, table


def _drop_the_form(data: dict[str, Any]) -> None:
    data["compositions"][0]["form_code"] = None


async def test_a_run_that_fails_inside_the_load_does_not_analyze(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Any
) -> None:
    broken = mutated_snapshot(tmp_path, _drop_the_form)
    before = await _last_analyze(engine)
    with pytest.raises(ImporterDataError):
        await run_import(sessionmaker, FixtureImporter(), broken)
    assert await _last_analyze(engine) == before


async def test_a_failed_analyze_leaves_the_run_committed_and_says_so(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    del sessionmaker  # requested for the clean catalog and the source row
    # ANALYZE waits for SHARE UPDATE EXCLUSIVE; inserts and updates do not conflict with it, so
    # only the ANALYZE of the run gives up when another session holds that lock.
    impatient = create_async_engine(
        TEST_DATABASE_URL, connect_args={"server_settings": {"lock_timeout": "300"}}
    )
    try:
        async with engine.connect() as blocker:
            await blocker.execute(
                text("LOCK TABLE catalog.recall_flags IN SHARE UPDATE EXCLUSIVE MODE")
            )
            with pytest.raises(AnalyzeFailed) as caught:
                await run_import(create_sessionmaker(impatient), FixtureImporter(), V1)
            await blocker.rollback()
    finally:
        await impatient.dispose()

    assert caught.value.code == "analyze_failed"
    runs = await rows(
        engine,
        "SELECT status, error_code FROM catalog.import_runs WHERE source = 'fixture'",
    )
    assert [tuple(r) for r in runs] == [("succeeded", None)]
    products = await rows(engine, "SELECT count(*) FROM catalog.products")
    assert products[0][0] == 3
