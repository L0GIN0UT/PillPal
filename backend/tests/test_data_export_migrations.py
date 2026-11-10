"""Revision 0021 (data exports): round trip, CHECKs, cascade."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from tests.helpers import downgrade, run_migrations
from tests.test_config_and_migrations import _recreate_db
from tests.test_entitlement_migrations import predecessor
from tests.test_relatives_migrations import _objects

DB = "pillpal_test_data_export_migrations"
REVISION = "0021_data_exports"


async def test_revision_upgrades_and_downgrades_cleanly() -> None:
    before = predecessor(REVISION)
    url = await _recreate_db(DB)
    run_migrations(url, before)
    engine = create_async_engine(url)
    try:
        baseline = await _objects(engine)
        run_migrations(url, REVISION)
        assert await _objects(engine) != baseline
        downgrade(url, before)
        assert await _objects(engine) == baseline  # the table and its indexes are gone
        run_migrations(url, REVISION)  # and it can be applied again
    finally:
        await engine.dispose()


async def _user(conn: Any) -> uuid.UUID:
    user_id = uuid.uuid4()
    await conn.execute(
        text(
            "INSERT INTO users (id, email, password_hash, region, locale) "
            "VALUES (:id, :e, 'x', 'ru', 'en')"
        ),
        {"id": user_id, "e": f"{user_id}@example.com"},
    )
    return user_id


async def _export(conn: Any, user_id: uuid.UUID, **values: Any) -> None:
    params = {
        "id": uuid.uuid4(),
        "u": user_id,
        "f": uuid.uuid4(),
        "status": "queued",
        "error": None,
        "archive": None,
    } | values
    await conn.execute(
        text(
            "INSERT INTO data_exports (id, user_id, family_id, status, error_code, archive) "
            "VALUES (:id, :u, :f, :status, :error, :archive)"
        ),
        params,
    )


@pytest.mark.parametrize(
    ("values", "constraint"),
    [
        ({"status": "pending"}, "status"),
        ({"error": "export_exploded"}, "error_code"),
        ({"archive": b"x"}, "archive_only_when_ready"),  # queued with an archive
        ({"status": "downloaded", "archive": b"x"}, "archive_only_when_ready"),
        ({"status": "expired", "archive": b"x"}, "archive_only_when_ready"),
    ],
)
async def test_checks_are_enforced(
    engine: AsyncEngine, values: dict[str, Any], constraint: str
) -> None:
    async with engine.connect() as conn:
        user_id = await _user(conn)
        with pytest.raises(DBAPIError, match=f"ck_data_exports_{constraint}"):
            await _export(conn, user_id, **values)
        await conn.rollback()


async def test_valid_rows_are_accepted_and_cascade_with_the_user(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        user_id = await _user(conn)
        await _export(conn, user_id)
        await _export(conn, user_id, status="ready", archive=b"blob")
        await _export(conn, user_id, status="failed", error="export_too_large")
        await _export(conn, user_id, status="failed", error="export_build_failed")
        assert (await conn.execute(text("SELECT count(*) FROM data_exports"))).scalar_one() == 4
        await conn.execute(text("DELETE FROM users WHERE id = :u"), {"u": user_id})
        assert (await conn.execute(text("SELECT count(*) FROM data_exports"))).scalar_one() == 0
