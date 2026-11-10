"""Revision 0017 (consents): round trip, CHECKs, the partial unique index and the cascade."""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from datetime import datetime
from typing import Any

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, create_async_engine

from tests.helpers import downgrade, run_migrations
from tests.test_config_and_migrations import _recreate_db, _tables

DB = "pillpal_test_consents_migrations"
BEFORE, REVISION = "0016_med_catalog_ref_index", "0017_consents"
ACCEPTED = "2026-11-10T12:00:00+00:00"


def test_revision_id_fits_alembic_version_column() -> None:
    assert len(REVISION) <= 32


async def test_revision_round_trips() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, BEFORE)
    engine = create_async_engine(url)
    try:
        assert "consents" not in await _tables(engine)
        run_migrations(url, REVISION)
        assert "consents" in await _tables(engine)
        downgrade(url, BEFORE)
        assert "consents" not in await _tables(engine)
        run_migrations(url, REVISION)
        assert "consents" in await _tables(engine)
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


async def _consent(conn: AsyncConnection, user_id: uuid.UUID, **overrides: Any) -> None:
    values: dict[str, Any] = {
        "id": uuid.uuid4(),
        "u": user_id,
        "kind": "terms",
        "version": 1,
        "source": "in_app",
        "accepted": ACCEPTED,
        "withdrawn": None,
    }
    values.update(overrides)
    for key in ("accepted", "withdrawn"):
        if values[key] is not None:
            values[key] = datetime.fromisoformat(values[key])
    await conn.execute(
        text(
            "INSERT INTO consents (id, user_id, kind, version, source, accepted_at, withdrawn_at) "
            "VALUES (:id, :u, :kind, :version, :source, CAST(:accepted AS timestamptz), "
            "CAST(:withdrawn AS timestamptz))"
        ),
        values,
    )


@pytest.mark.parametrize(
    "overrides",
    [
        {"kind": "ads"},
        {"source": "import"},
        {"version": 0},
        {"version": 1001},
        {"withdrawn": "2026-11-10T11:59:59+00:00"},  # before accepted_at
    ],
)
async def test_checks_refuse_bad_rows(
    checks_engine: AsyncEngine, overrides: dict[str, Any]
) -> None:
    async with checks_engine.connect() as conn:
        user_id = await _user(conn)
        with pytest.raises(IntegrityError):
            await _consent(conn, user_id, **overrides)


async def test_every_kind_and_source_is_accepted(checks_engine: AsyncEngine) -> None:
    kinds = ("health_data", "terms", "privacy", "catalog_contribution")
    sources = ("registration", "in_app", "oauth_signup", "medication_link")
    async with checks_engine.begin() as conn:
        user_id = await _user(conn)
        for kind in kinds:
            for source in sources:
                await _consent(conn, user_id, kind=kind, source=source, version=1000)
                await _consent(conn, user_id, kind=kind, source=source, version=1, withdrawn=None)
                await conn.execute(text("DELETE FROM consents WHERE user_id = :u"), {"u": user_id})


async def test_one_active_record_per_user_kind_and_version(checks_engine: AsyncEngine) -> None:
    async with checks_engine.connect() as conn:
        user_id = await _user(conn)
        await _consent(conn, user_id)
        await _consent(conn, user_id, version=2)  # another version
        await _consent(conn, user_id, kind="privacy")  # another kind
        await _consent(conn, await _user(conn))  # another user
        with pytest.raises(IntegrityError):
            await _consent(conn, user_id)


async def test_a_withdrawn_record_makes_room_for_a_new_acceptance(
    checks_engine: AsyncEngine,
) -> None:
    async with checks_engine.begin() as conn:
        user_id = await _user(conn)
        await _consent(conn, user_id, withdrawn="2026-11-11T00:00:00+00:00")
        await _consent(conn, user_id)
        await _consent(conn, user_id, withdrawn="2026-11-12T00:00:00+00:00")  # history grows


async def test_deleting_the_user_deletes_the_records(checks_engine: AsyncEngine) -> None:
    async with checks_engine.begin() as conn:
        user_id = await _user(conn)
        await _consent(conn, user_id)
        await conn.execute(text("DELETE FROM users WHERE id = :u"), {"u": user_id})
        count = (
            await conn.execute(
                text("SELECT count(*) FROM consents WHERE user_id = :u"), {"u": user_id}
            )
        ).scalar_one()
    assert count == 0


async def test_a_record_needs_an_existing_user(checks_engine: AsyncEngine) -> None:
    async with checks_engine.connect() as conn:
        with pytest.raises(IntegrityError):
            await _consent(conn, uuid.uuid4())
