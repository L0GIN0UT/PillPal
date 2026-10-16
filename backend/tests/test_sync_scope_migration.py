"""Revision 0007: journal keyed by profile and the ``privacy`` op (ADR 0006 §1), ``granted_seq``."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, create_async_engine

from tests.helpers import downgrade, run_migrations
from tests.test_config_and_migrations import _recreate_db

BEFORE = "0006_profile_alert_settings"
REVISION = "0007_sync_changes_scope"


def uid() -> str:
    return str(uuid.uuid4())


async def _seed(conn: AsyncConnection) -> dict[str, str]:
    """One account with the whole entity graph, journaled the way revision 0006 did."""
    ids = {
        k: uid()
        for k in (
            "user",
            "profile",
            "managed",
            "med",
            "sched",
            "event",
            "orphan",
            "relative",
            "grant",
        )
    }
    await conn.execute(
        text(
            "INSERT INTO users (id, email, password_hash, region, locale) "
            "VALUES (:id, 'seed@example.com', 'x', 'ru', 'en')"
        ),
        {"id": ids["user"]},
    )
    await conn.execute(
        text(
            "INSERT INTO users (id, email, password_hash, region, locale) "
            "VALUES (:id, 'relative@example.com', 'x', 'ru', 'en')"
        ),
        {"id": ids["relative"]},
    )
    for key, kind in (("profile", "self"), ("managed", "managed")):
        await conn.execute(
            text(
                "INSERT INTO profiles (id, owner_user_id, kind, display_name, timezone, "
                "client_updated_at) VALUES (:id, :u, :kind, 'Synthetic', 'UTC', now())"
            ),
            {"id": ids[key], "u": ids["user"], "kind": kind},
        )
    await conn.execute(
        text(
            "INSERT INTO medications (id, profile_id, name, client_updated_at) "
            "VALUES (:id, :p, 'Synthetic med', now())"
        ),
        {"id": ids["med"], "p": ids["managed"]},
    )
    await conn.execute(
        text(
            "INSERT INTO schedules (id, medication_id, rule, client_updated_at) "
            'VALUES (:id, :m, \'{"v": 1, "kind": "daily"}\'::jsonb, now())'
        ),
        {"id": ids["sched"], "m": ids["med"]},
    )
    await conn.execute(
        text(
            "INSERT INTO dose_events (id, profile_id, medication_id, type, at) "
            "VALUES (:id, :p, :m, 'taken', now())"
        ),
        {"id": ids["event"], "p": ids["managed"], "m": ids["med"]},
    )
    await conn.execute(
        text(
            "INSERT INTO profile_grants (id, profile_id, grantee_user_id, role, "
            "disclosure_version) VALUES (:g, :p, :u, 'viewer', 1)"
        ),
        {"g": ids["grant"], "p": ids["managed"], "u": ids["relative"]},
    )
    journal: list[tuple[str, str]] = [
        ("profile", ids["profile"]),
        ("profile", ids["managed"]),
        ("medication", ids["med"]),
        ("schedule", ids["sched"]),
        ("dose_event", ids["event"]),
        ("medication", ids["orphan"]),  # no such entity: cannot be assigned to a profile
    ]
    for entity, entity_id in journal:
        await conn.execute(
            text(
                "INSERT INTO sync_changes (user_id, entity, entity_id, op) "
                "VALUES (:u, :e, :i, 'upsert')"
            ),
            {"u": ids["user"], "e": entity, "i": entity_id},
        )
    return ids


async def _journal(engine: AsyncEngine, column: str) -> dict[str, Any]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text(f"SELECT entity_id, {column}, op FROM sync_changes")  # noqa: S608 - test constant
        )
        return {str(r[0]): (str(r[1]), r[2]) for r in rows}


async def test_upgrade_assigns_every_journal_row_to_its_profile_and_downgrade_restores_owner() -> (
    None
):
    url = await _recreate_db("pillpal_test_migration_0007")
    run_migrations(url, BEFORE)
    engine = create_async_engine(url)
    try:
        async with engine.begin() as conn:
            ids = await _seed(conn)
        run_migrations(url, REVISION)

        scoped = await _journal(engine, "profile_id")
        assert scoped[ids["profile"]][0] == ids["profile"]
        assert scoped[ids["managed"]][0] == ids["managed"]
        assert scoped[ids["med"]][0] == ids["managed"]
        assert scoped[ids["sched"]][0] == ids["managed"]
        assert scoped[ids["event"]][0] == ids["managed"]
        assert ids["orphan"] not in scoped  # dropped: nothing to deliver
        await _check_granted_seq(engine, ids)

        async with engine.connect() as conn:
            columns = {
                r[0]
                for r in await conn.execute(
                    text(
                        "SELECT column_name FROM information_schema.columns "
                        "WHERE table_name = 'sync_changes'"
                    )
                )
            }
        assert "user_id" not in columns
        assert "profile_id" in columns

        # The new op is accepted, and the profile cascade removes the journal.
        async with engine.begin() as conn:
            await conn.execute(
                text(
                    "INSERT INTO sync_changes (profile_id, entity, entity_id, op) "
                    "VALUES (:p, 'medication', :m, 'privacy')"
                ),
                {"p": ids["managed"], "m": ids["med"]},
            )
        downgrade(url, BEFORE)
        await _check_granted_seq_dropped(engine)

        restored = await _journal(engine, "user_id")
        assert {v[0] for v in restored.values()} == {ids["user"]}
        assert {v[1] for v in restored.values()} == {"upsert"}  # privacy rows became upserts
        run_migrations(url, REVISION)  # and it can be applied again
    finally:
        await engine.dispose()


async def test_journal_rows_follow_their_profile_on_delete_and_reject_unknown_ops() -> None:
    url = await _recreate_db("pillpal_test_migration_0007_checks")
    run_migrations(url, REVISION)
    engine = create_async_engine(url)
    try:
        async with engine.begin() as conn:
            user, profile = uid(), uid()
            await conn.execute(
                text(
                    "INSERT INTO users (id, email, password_hash, region, locale) "
                    "VALUES (:id, 'c@example.com', 'x', 'ru', 'en')"
                ),
                {"id": user},
            )
            await conn.execute(
                text(
                    "INSERT INTO profiles (id, owner_user_id, kind, display_name, timezone, "
                    "client_updated_at) VALUES (:id, :u, 'self', 'S', 'UTC', now())"
                ),
                {"id": profile, "u": user},
            )
            await conn.execute(
                text(
                    "INSERT INTO sync_changes (profile_id, entity, entity_id, op) "
                    "VALUES (:p, 'profile', :p, 'upsert')"
                ),
                {"p": profile},
            )
        async with engine.connect() as conn:
            with pytest.raises(DBAPIError, match="ck_sync_changes_op"):
                await conn.execute(
                    text(
                        "INSERT INTO sync_changes (profile_id, entity, entity_id, op) "
                        "VALUES (:p, 'profile', :p, 'bogus')"
                    ),
                    {"p": profile},
                )
            await conn.rollback()
            indexes = [
                r[0]
                for r in await conn.execute(
                    text("SELECT indexdef FROM pg_indexes WHERE tablename = 'sync_changes'")
                )
            ]
        assert any("(profile_id, seq)" in d for d in indexes)
        async with engine.begin() as conn:
            await conn.execute(text("DELETE FROM profiles"))
            left = (await conn.execute(text("SELECT count(*) FROM sync_changes"))).scalar_one()
        assert left == 0
    finally:
        await engine.dispose()


async def _check_granted_seq(engine: AsyncEngine, ids: dict[str, str]) -> None:
    """An existing grant starts at the journal head of its profile; negatives are refused."""
    async with engine.connect() as conn:
        head = (
            await conn.execute(
                text("SELECT max(seq) FROM sync_changes WHERE profile_id = :p"),
                {"p": ids["managed"]},
            )
        ).scalar_one()
        stored = (
            await conn.execute(
                text("SELECT granted_seq FROM profile_grants WHERE id = :g"), {"g": ids["grant"]}
            )
        ).scalar_one()
        assert stored == head
        with pytest.raises(DBAPIError, match="granted_seq"):
            await conn.execute(text("UPDATE profile_grants SET granted_seq = -1"))
        await conn.rollback()


async def _check_granted_seq_dropped(engine: AsyncEngine) -> None:
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
