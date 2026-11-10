"""Revision 0022 (auth_identities): round trip, CHECKs, UNIQUE (provider, subject), the cascade."""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from typing import Any

import pytest
import pytest_asyncio
from alembic.script import ScriptDirectory
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, create_async_engine

from tests.helpers import alembic_config, downgrade, run_migrations
from tests.test_config_and_migrations import _recreate_db, _tables

DB = "pillpal_test_identities_migrations"
REVISION = "0022_auth_identities"


def _previous_revision() -> str:
    """The revision it follows (it moves when the milestones before it merge)."""
    script = ScriptDirectory.from_config(alembic_config("postgresql+asyncpg://unused/unused"))
    revision = script.get_revision(REVISION)
    assert revision is not None
    assert isinstance(revision.down_revision, str)
    return revision.down_revision


BEFORE = _previous_revision()


def test_revision_id_fits_alembic_version_column() -> None:
    assert len(REVISION) <= 32


async def test_revision_round_trips() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, BEFORE)
    engine = create_async_engine(url)
    try:
        assert "auth_identities" not in await _tables(engine)
        run_migrations(url, REVISION)
        assert "auth_identities" in await _tables(engine)
        downgrade(url, BEFORE)
        assert "auth_identities" not in await _tables(engine)
        run_migrations(url, REVISION)
        assert "auth_identities" in await _tables(engine)
    finally:
        await engine.dispose()


@pytest_asyncio.fixture(scope="module")
async def checks_engine() -> AsyncIterator[AsyncEngine]:
    url = await _recreate_db(DB + "_checks")
    run_migrations(url, REVISION)
    engine = create_async_engine(url)
    yield engine
    await engine.dispose()


async def _user(conn: AsyncConnection) -> uuid.UUID:
    user_id = uuid.uuid4()
    await conn.execute(
        text(
            "INSERT INTO users (id, email, password_hash, region) VALUES (:id, :email, 'x', 'ru')"
        ),
        {"id": user_id, "email": f"{user_id.hex[:8]}@example.com"},
    )
    return user_id


async def _identity(conn: AsyncConnection, user_id: uuid.UUID, **overrides: Any) -> None:
    values: dict[str, Any] = {
        "id": uuid.uuid4(),
        "u": user_id,
        "provider": "vk_id",
        "subject": uuid.uuid4().hex,
    }
    values.update(overrides)
    await conn.execute(
        text(
            "INSERT INTO auth_identities (id, user_id, provider, subject) "
            "VALUES (:id, :u, :provider, :subject)"
        ),
        values,
    )


@pytest.mark.parametrize(
    "overrides",
    [{"provider": "facebook"}, {"provider": ""}, {"subject": ""}, {"subject": "x" * 256}],
)
async def test_checks_refuse_bad_rows(
    checks_engine: AsyncEngine, overrides: dict[str, Any]
) -> None:
    async with checks_engine.connect() as conn:
        user_id = await _user(conn)
        with pytest.raises(IntegrityError):
            await _identity(conn, user_id, **overrides)


async def test_every_provider_and_the_longest_subject_are_accepted(
    checks_engine: AsyncEngine,
) -> None:
    async with checks_engine.begin() as conn:
        user_id = await _user(conn)
        for provider in ("apple", "google", "vk_id", "yandex_id"):
            await _identity(conn, user_id, provider=provider, subject="s" * 255)


async def test_a_provider_subject_belongs_to_one_account(checks_engine: AsyncEngine) -> None:
    async with checks_engine.connect() as conn:
        first, second = await _user(conn), await _user(conn)
        await _identity(conn, first, provider="google", subject="same")
        await _identity(conn, first, provider="apple", subject="same")  # another provider
        await _identity(conn, second, provider="vk_id", subject="same")
        with pytest.raises(IntegrityError):
            await _identity(conn, second, provider="google", subject="same")


async def test_an_account_may_hold_several_identities(checks_engine: AsyncEngine) -> None:
    async with checks_engine.begin() as conn:
        user_id = await _user(conn)
        await _identity(conn, user_id, provider="vk_id")
        await _identity(conn, user_id, provider="yandex_id")


async def test_deleting_the_user_deletes_the_identities(checks_engine: AsyncEngine) -> None:
    async with checks_engine.begin() as conn:
        user_id = await _user(conn)
        await _identity(conn, user_id)
        await conn.execute(text("DELETE FROM users WHERE id = :u"), {"u": user_id})
        left = (
            await conn.execute(
                text("SELECT count(*) FROM auth_identities WHERE user_id = :u"), {"u": user_id}
            )
        ).scalar_one()
    assert left == 0


async def test_an_identity_needs_an_existing_user(checks_engine: AsyncEngine) -> None:
    async with checks_engine.connect() as conn:
        with pytest.raises(IntegrityError):
            await _identity(conn, uuid.uuid4())
