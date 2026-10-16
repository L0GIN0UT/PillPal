"""Revision 0008: ``profile_grants.granted_seq`` starts at the profile's journal head."""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import create_async_engine

from tests.helpers import downgrade, run_migrations
from tests.test_config_and_migrations import _recreate_db

BEFORE = "0007_sync_changes_scope"
REVISION = "0008_grant_granted_seq"


async def test_existing_grants_get_the_current_journal_head_and_downgrade_drops_it() -> None:
    url = await _recreate_db("pillpal_test_migration_0008")
    run_migrations(url, BEFORE)
    engine = create_async_engine(url)
    owner, relative, profile, grant = (str(uuid.uuid4()) for _ in range(4))
    try:
        async with engine.begin() as conn:
            for user, email in ((owner, "o@example.com"), (relative, "r@example.com")):
                await conn.execute(
                    text(
                        "INSERT INTO users (id, email, password_hash, region, locale) "
                        "VALUES (:id, :e, 'x', 'ru', 'en')"
                    ),
                    {"id": user, "e": email},
                )
            await conn.execute(
                text(
                    "INSERT INTO profiles (id, owner_user_id, kind, display_name, timezone, "
                    "client_updated_at) VALUES (:id, :u, 'self', 'S', 'UTC', now())"
                ),
                {"id": profile, "u": owner},
            )
            for _ in range(3):
                await conn.execute(
                    text(
                        "INSERT INTO sync_changes (profile_id, entity, entity_id, op) "
                        "VALUES (:p, 'profile', :p, 'upsert')"
                    ),
                    {"p": profile},
                )
            await conn.execute(
                text(
                    "INSERT INTO profile_grants (id, profile_id, grantee_user_id, role, "
                    "disclosure_version) VALUES (:g, :p, :u, 'viewer', 1)"
                ),
                {"g": grant, "p": profile, "u": relative},
            )
            head = (await conn.execute(text("SELECT max(seq) FROM sync_changes"))).scalar_one()
        run_migrations(url, REVISION)
        async with engine.connect() as conn:
            stored = (
                await conn.execute(
                    text("SELECT granted_seq FROM profile_grants WHERE id = :g"), {"g": grant}
                )
            ).scalar_one()
            assert stored == head
            with pytest.raises(DBAPIError, match="granted_seq"):
                await conn.execute(text("UPDATE profile_grants SET granted_seq = -1"))
            await conn.rollback()
        downgrade(url, BEFORE)
        async with engine.connect() as conn:
            columns = {
                r[0]
                for r in await conn.execute(
                    text(
                        "SELECT column_name FROM information_schema.columns "
                        "WHERE table_name = 'profile_grants'"
                    )
                )
            }
        assert "granted_seq" not in columns
        run_migrations(url, REVISION)
    finally:
        await engine.dispose()
