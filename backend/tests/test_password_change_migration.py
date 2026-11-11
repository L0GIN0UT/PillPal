"""Revision 0024: ``password_change`` joins the e-mail code purposes; downgrade drops its rows."""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncConnection, create_async_engine

from tests.helpers import downgrade, run_migrations
from tests.test_config_and_migrations import _recreate_db

DB = "pillpal_test_password_change_migration"
REVISION = "0024_password_change_purpose"
BEFORE = "0023_purchases"
INSERT = text(
    "INSERT INTO email_codes (id, user_id, purpose, code_hash, expires_at) "
    "VALUES (:i, :u, :p, 'h', now())"
)


def test_revision_id_fits_alembic_version_column() -> None:
    assert len(REVISION) <= 32


async def _user(conn: AsyncConnection) -> uuid.UUID:
    user_id = uuid.uuid4()
    await conn.execute(
        text(
            "INSERT INTO users (id, email, password_hash, region) VALUES (:id, :email, 'x', 'ru')"
        ),
        {"id": user_id, "email": f"{user_id.hex[:8]}@example.com"},
    )
    return user_id


async def test_the_purpose_is_accepted_after_the_upgrade_and_refused_before() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, BEFORE)
    engine = create_async_engine(url)
    try:
        async with engine.connect() as conn:
            user_id = await _user(conn)
            await conn.commit()
            with pytest.raises(DBAPIError, match="ck_email_codes_purpose"):
                await conn.execute(
                    INSERT, {"i": uuid.uuid4(), "u": user_id, "p": "password_change"}
                )
            await conn.rollback()
        run_migrations(url, REVISION)
        async with engine.connect() as conn:
            user_id = (await conn.execute(text("SELECT id FROM users"))).scalar_one()
            for purpose, ok in (("password_change", True), ("bogus", False)):
                params = {"i": uuid.uuid4(), "u": user_id, "p": purpose}
                if ok:
                    await conn.execute(INSERT, params)
                else:
                    with pytest.raises(DBAPIError, match="ck_email_codes_purpose"):
                        await conn.execute(INSERT, params)
                    await conn.rollback()
    finally:
        await engine.dispose()


async def test_the_downgrade_deletes_the_rows_it_would_orphan() -> None:
    url = await _recreate_db(DB + "_down")
    run_migrations(url, REVISION)
    engine = create_async_engine(url)
    try:
        async with engine.begin() as conn:
            user_id = await _user(conn)
            for purpose in ("password_change", "password_reset"):
                await conn.execute(INSERT, {"i": uuid.uuid4(), "u": user_id, "p": purpose})
        downgrade(url, BEFORE)
        async with engine.connect() as conn:
            left = (await conn.execute(text("SELECT purpose FROM email_codes"))).scalars().all()
        assert left == ["password_reset"]
    finally:
        await engine.dispose()
