"""Revisions 0018 (entitlements) and 0019 (admin audit): round trips and CHECKs."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from alembic.script import ScriptDirectory
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from tests.helpers import alembic_config, downgrade, register, run_migrations
from tests.test_config_and_migrations import _recreate_db
from tests.test_relatives_migrations import _objects

DB = "pillpal_test_entitlement_migrations"
REVISIONS = ["0018_entitlements", "0019_admin_audit"]
NOW = datetime(2026, 11, 10, 12, 0, tzinfo=UTC)


def predecessor(revision: str) -> str:
    """The revision before ``revision`` (0017 once the consents milestone is merged)."""
    script = ScriptDirectory.from_config(alembic_config("postgresql+asyncpg://unused/unused"))
    down = script.get_revision(revision).down_revision
    assert isinstance(down, str)
    return down


def test_the_chain_is_in_the_reserved_order() -> None:
    assert predecessor("0019_admin_audit") == "0018_entitlements"


@pytest.mark.parametrize("revision", REVISIONS)
async def test_revision_upgrades_and_downgrades_cleanly(revision: str) -> None:
    before = predecessor(revision)
    url = await _recreate_db(DB)
    run_migrations(url, before)
    engine = create_async_engine(url)
    try:
        baseline = await _objects(engine)
        run_migrations(url, revision)
        assert await _objects(engine) != baseline
        downgrade(url, before)
        assert await _objects(engine) == baseline  # tables and indexes all gone
        run_migrations(url, revision)  # and it can be applied again
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


async def _entitlement(conn: Any, user_id: uuid.UUID, **values: Any) -> None:
    params = {
        "id": uuid.uuid4(),
        "u": user_id,
        "kind": "ads_removed",
        "source": "promo",
        "granted": NOW,
        "expires": None,
    } | values
    await conn.execute(
        text(
            "INSERT INTO entitlements (id, user_id, kind, source, granted_at, expires_at) "
            "VALUES (:id, :u, :kind, :source, :granted, :expires)"
        ),
        params,
    )


@pytest.mark.parametrize(
    ("values", "constraint"),
    [
        ({"kind": "everything"}, "kind"),
        ({"source": "gift"}, "source"),
        ({"expires": NOW}, "expires_after_granted"),  # equal to granted_at
        ({"expires": NOW - timedelta(seconds=1)}, "expires_after_granted"),
    ],
)
async def test_entitlement_checks_are_enforced(
    engine: AsyncEngine, values: dict[str, Any], constraint: str
) -> None:
    async with engine.connect() as conn:
        user_id = await _user(conn)
        with pytest.raises(DBAPIError, match=f"ck_entitlements_{constraint}"):
            await _entitlement(conn, user_id, **values)
        await conn.rollback()


async def test_entitlements_cascade_with_the_user_and_accept_valid_rows(
    engine: AsyncEngine,
) -> None:
    async with engine.begin() as conn:
        user_id = await _user(conn)
        await _entitlement(conn, user_id)
        await _entitlement(conn, user_id, kind="limits_lifted", expires=NOW + timedelta(days=1))
        count = (await conn.execute(text("SELECT count(*) FROM entitlements"))).scalar_one()
        assert count == 2
        await conn.execute(text("DELETE FROM users WHERE id = :u"), {"u": user_id})
        count = (await conn.execute(text("SELECT count(*) FROM entitlements"))).scalar_one()
        assert count == 0


async def _audit(conn: Any, **values: Any) -> None:
    params = {
        "id": uuid.uuid4(),
        "actor": "ops-1",
        "action": "entitlement_grant",
        "target": None,
        "kind": "ads_removed",
        "os_user": "root",
        "host": "host-1",
    } | values
    await conn.execute(
        text(
            "INSERT INTO admin_audit (id, actor, action, target_user_id, kind, os_user, host) "
            "VALUES (:id, :actor, :action, :target, :kind, :os_user, :host)"
        ),
        params,
    )


@pytest.mark.parametrize(
    ("values", "constraint"),
    [
        ({"actor": ""}, "actor"),
        ({"actor": "a" * 65}, "actor"),
        ({"actor": "someone@example.com"}, "actor"),
        ({"action": "delete_everything"}, "action"),
        ({"kind": "gold"}, "kind"),
        ({"os_user": "root@host"}, "operator_fields"),
        ({"host": "host@example.com"}, "operator_fields"),
        ({"host": "h" * 256}, "operator_fields"),
    ],
)
async def test_audit_checks_are_enforced(
    engine: AsyncEngine, values: dict[str, Any], constraint: str
) -> None:
    async with engine.connect() as conn:
        with pytest.raises(DBAPIError, match=f"ck_admin_audit_{constraint}"):
            await _audit(conn, **values)
        await conn.rollback()


async def test_audit_accepts_a_boundary_actor_and_missing_operator_fields(
    engine: AsyncEngine,
) -> None:
    async with engine.begin() as conn:
        await _audit(conn, actor="a" * 64, kind=None, os_user=None, host=None)
        count = (await conn.execute(text("SELECT count(*) FROM admin_audit"))).scalar_one()
        assert count == 1


async def test_deleting_the_user_keeps_the_audit_row_with_a_null_target(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    async with engine.begin() as conn:
        await _audit(conn, target=uuid.UUID(user.id))
        await conn.execute(text("DELETE FROM users WHERE id = :u"), {"u": uuid.UUID(user.id)})
        row = (await conn.execute(text("SELECT target_user_id FROM admin_audit"))).one()
        assert row[0] is None
