"""Revision 0023 (purchases): round trip, CHECKs, deduplication and cascade."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from alembic.script import ScriptDirectory
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError, IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from tests.helpers import alembic_config, downgrade, run_migrations
from tests.test_config_and_migrations import _recreate_db
from tests.test_relatives_migrations import _objects

DB = "pillpal_test_payments_migrations"
REVISION = "0023_purchases"


def test_the_revision_follows_the_reserved_predecessor() -> None:
    script = ScriptDirectory.from_config(alembic_config("postgresql+asyncpg://unused/unused"))
    assert script.get_revision(REVISION).down_revision == "0022_auth_identities"


async def test_the_revision_upgrades_and_downgrades_cleanly() -> None:
    before = "0022_auth_identities"
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


async def _purchase(conn: Any, user_id: uuid.UUID, **values: Any) -> None:
    params = {
        "id": uuid.uuid4(),
        "u": user_id,
        "store": "app_store",
        "product": "synthetic.remove_ads",
        "original": "2000000000001",
        "env": "production",
    } | values
    await conn.execute(
        text(
            "INSERT INTO purchases (id, user_id, store, product_id, original_transaction_id, "
            "environment, purchased_at, verified_at) "
            "VALUES (:id, :u, :store, :product, :original, :env, now(), now())"
        ),
        params,
    )


@pytest.mark.parametrize(
    ("values", "constraint"),
    [
        ({"store": "play_pass"}, "store"),
        ({"env": "xcode"}, "environment"),
        ({"product": ""}, "product_id"),
        ({"product": "p" * 256}, "product_id"),
        ({"original": ""}, "original_transaction_id"),
        ({"original": "o" * 256}, "original_transaction_id"),
    ],
)
async def test_checks_are_enforced(
    engine: AsyncEngine, values: dict[str, Any], constraint: str
) -> None:
    async with engine.connect() as conn:
        user_id = await _user(conn)
        with pytest.raises(DBAPIError, match=f"ck_purchases_{constraint}"):
            await _purchase(conn, user_id, **values)
        await conn.rollback()


async def test_one_purchase_belongs_to_one_account_per_store(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        first, second = await _user(conn), await _user(conn)
        await _purchase(conn, first)
        with pytest.raises(IntegrityError, match="uq_purchases_store_original_transaction_id"):
            await _purchase(conn, second)
        await conn.rollback()


async def test_the_same_identifier_in_another_store_is_another_purchase(
    engine: AsyncEngine,
) -> None:
    async with engine.begin() as conn:
        user_id = await _user(conn)
        await _purchase(conn, user_id)
        await _purchase(conn, user_id, store="rustore")
        count = (await conn.execute(text("SELECT count(*) FROM purchases"))).scalar_one()
        assert count == 2


async def test_purchases_cascade_with_the_user(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        user_id = await _user(conn)
        await _purchase(conn, user_id)
        await conn.execute(text("DELETE FROM users WHERE id = :u"), {"u": user_id})
        count = (await conn.execute(text("SELECT count(*) FROM purchases"))).scalar_one()
        assert count == 0
