"""Step-by-step round trips of the relatives revisions (0004-0006)."""

from __future__ import annotations

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from tests.helpers import downgrade, run_migrations
from tests.test_config_and_migrations import _recreate_db

STEPS = [
    ("0003_medication_stock_set_at", "0004_profile_grants"),
    ("0004_profile_grants", "0005_invites"),
    ("0005_invites", "0006_profile_alert_settings"),
]

OBJECTS_SQL = {
    "tables": "SELECT tablename FROM pg_tables WHERE schemaname = 'public'",
    "functions": (
        "SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
        "WHERE n.nspname = 'public'"
    ),
    "triggers": "SELECT tgname FROM pg_trigger WHERE NOT tgisinternal",
    "profile_columns": (
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'profiles'"
    ),
}


async def _objects(engine: AsyncEngine) -> dict[str, set[str]]:
    async with engine.connect() as conn:
        return {
            kind: {row[0] for row in await conn.execute(text(sql))}
            for kind, sql in OBJECTS_SQL.items()
        }


@pytest.mark.parametrize(("before", "revision"), STEPS)
async def test_revision_upgrades_and_downgrades_cleanly(before: str, revision: str) -> None:
    url = await _recreate_db("pillpal_test_migration_steps")
    run_migrations(url, before)
    engine = create_async_engine(url)
    try:
        baseline = await _objects(engine)
        run_migrations(url, revision)
        assert await _objects(engine) != baseline
        downgrade(url, before)
        assert await _objects(engine) == baseline  # tables, functions and triggers all gone
        run_migrations(url, revision)  # and it can be applied again
    finally:
        await engine.dispose()
