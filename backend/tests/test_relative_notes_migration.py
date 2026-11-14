"""Revision 0025: ``relative_notes`` (ADR 0020 section 4): invariants in PostgreSQL, reversible."""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncConnection, create_async_engine

from tests.helpers import downgrade, run_migrations
from tests.test_config_and_migrations import _recreate_db

DB = "pillpal_test_relnotes_migration"
REVISION = "0025_relative_notes"
BEFORE = "0024_password_change_purpose"
INSERT_NOTE = text(
    "INSERT INTO relative_notes (user_id, subject_profile_id, note) VALUES (:u, :p, :n)"
)


def test_revision_id_fits_alembic_version_column() -> None:
    assert len(REVISION) <= 32


async def _user_with_profile(conn: AsyncConnection) -> tuple[uuid.UUID, uuid.UUID]:
    user_id, profile_id = uuid.uuid4(), uuid.uuid4()
    await conn.execute(
        text("INSERT INTO users (id, email, password_hash, region) VALUES (:i, :e, 'x', 'ru')"),
        {"i": user_id, "e": f"{user_id.hex[:8]}@example.com"},
    )
    await conn.execute(
        text(
            "INSERT INTO profiles (id, owner_user_id, kind, display_name, timezone, "
            "client_updated_at) VALUES (:i, :u, 'self', 'Synthetic', 'UTC', now())"
        ),
        {"i": profile_id, "u": user_id},
    )
    return user_id, profile_id


async def _tables(conn: AsyncConnection) -> set[str]:
    rows = await conn.execute(text("SELECT tablename FROM pg_tables WHERE schemaname = 'public'"))
    return {row[0] for row in rows}


async def test_notes_table_checks_cascades_and_downgrade() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, BEFORE)
    engine = create_async_engine(url)
    try:
        async with engine.connect() as conn:
            assert "relative_notes" not in await _tables(conn)
        run_migrations(url, REVISION)
        async with engine.connect() as conn:
            author, _ = await _user_with_profile(conn)
            subject_user, subject = await _user_with_profile(conn)
            await conn.execute(INSERT_NOTE, {"u": author, "p": subject, "n": "Сын"})
            await conn.commit()
            for bad in ("", "x" * 21):
                with pytest.raises(DBAPIError, match="ck_relative_notes_note_length"):
                    await conn.execute(INSERT_NOTE, {"u": subject_user, "p": subject, "n": bad})
                await conn.rollback()
            # One note per (author, subject).
            with pytest.raises(DBAPIError, match="pk_relative_notes"):
                await conn.execute(INSERT_NOTE, {"u": author, "p": subject, "n": "Again"})
            await conn.rollback()
            # The subject's profile going takes the note with it; so does the author.
            await conn.execute(text("DELETE FROM profiles WHERE id = :p"), {"p": subject})
            assert (await conn.execute(text("SELECT count(*) FROM relative_notes"))).scalar() == 0
            _, other = await _user_with_profile(conn)
            await conn.execute(INSERT_NOTE, {"u": author, "p": other, "n": "Мама"})
            await conn.execute(text("DELETE FROM users WHERE id = :u"), {"u": author})
            assert (await conn.execute(text("SELECT count(*) FROM relative_notes"))).scalar() == 0
            await conn.commit()
        downgrade(url, BEFORE)
        async with engine.connect() as conn:
            assert "relative_notes" not in await _tables(conn)
        run_migrations(url, REVISION)
    finally:
        await engine.dispose()
