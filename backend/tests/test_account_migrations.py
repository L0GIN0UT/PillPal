"""Revisions 0008 (deletion grace) and 0009 (profile archive): round trips and CHECKs."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from tests.helpers import downgrade, run_migrations
from tests.test_config_and_migrations import _recreate_db
from tests.test_relatives_migrations import _objects

DB = "pillpal_test_grace_migrations"
STEPS = [
    ("0007_sync_changes_scope", "0008_user_deletion_grace"),
    ("0008_user_deletion_grace", "0009_profile_archive"),
]


@pytest.mark.parametrize(("before", "revision"), STEPS)
async def test_revision_upgrades_and_downgrades_cleanly(before: str, revision: str) -> None:
    url = await _recreate_db(DB)
    run_migrations(url, before)
    engine = create_async_engine(url)
    try:
        baseline = await _objects(engine)
        columns_before = await _columns(engine)
        run_migrations(url, revision)
        assert await _columns(engine) != columns_before
        downgrade(url, before)
        assert await _objects(engine) == baseline
        assert await _columns(engine) == columns_before
        run_migrations(url, revision)  # and it can be applied again
    finally:
        await engine.dispose()


async def _columns(engine: AsyncEngine) -> set[tuple[str, str]]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text(
                "SELECT table_name, column_name FROM information_schema.columns "
                "WHERE table_schema = 'public' AND table_name IN ('users', 'profiles')"
            )
        )
        return {(r[0], r[1]) for r in rows}


async def _user(conn: Any, **columns: str) -> uuid.UUID:
    user_id = uuid.uuid4()
    names = ["id", "email", "password_hash", "region", *columns]
    values = [":id", ":email", "'x'", "'ru'", *columns.values()]
    await conn.execute(
        text(f"INSERT INTO users ({', '.join(names)}) VALUES ({', '.join(values)})"),  # noqa: S608
        {"id": user_id, "email": f"{user_id.hex[:8]}@example.com"},
    )
    return user_id


async def _profile(conn: Any, owner: uuid.UUID, kind: str = "managed", **columns: str) -> None:
    names = ["id", "owner_user_id", "kind", "display_name", "timezone", "client_updated_at"]
    values = [":id", ":owner", ":kind", "'Ward'", "'UTC'", "now()", *columns.values()]
    sql = f"INSERT INTO profiles ({', '.join([*names, *columns])}) VALUES ({', '.join(values)})"  # noqa: S608
    await conn.execute(text(sql), {"id": uuid.uuid4(), "owner": owner, "kind": kind})


@pytest.mark.parametrize(
    "columns",
    [
        {"deletion_requested_at": "now()"},  # one without the other
        {"erase_after": "now() + interval '1 day'"},
        {"deletion_requested_at": "now()", "erase_after": "now() - interval '1 day'"},
    ],
)
async def test_user_deletion_columns_are_checked(columns: dict[str, str]) -> None:
    url = await _recreate_db(DB)
    run_migrations(url, "0008_user_deletion_grace")
    engine = create_async_engine(url)
    try:
        async with engine.connect() as conn:
            with pytest.raises(DBAPIError, match="ck_users_deletion"):
                await _user(conn, **columns)
            await conn.rollback()
            await _user(
                conn,
                deletion_requested_at="now()",
                erase_after="now() + interval '1 day'",
            )
    finally:
        await engine.dispose()


async def test_restore_account_is_an_email_code_purpose() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, "0008_user_deletion_grace")
    engine = create_async_engine(url)
    try:
        async with engine.connect() as conn:
            user_id = await _user(conn)
            for purpose, ok in (("restore_account", True), ("bogus", False)):
                stmt = text(
                    "INSERT INTO email_codes (id, user_id, purpose, code_hash, expires_at) "
                    "VALUES (:i, :u, :p, 'h', now())"
                )
                params = {"i": uuid.uuid4(), "u": user_id, "p": purpose}
                if ok:
                    await conn.execute(stmt, params)
                else:
                    with pytest.raises(DBAPIError, match="ck_email_codes_purpose"):
                        await conn.execute(stmt, params)
                    await conn.rollback()
    finally:
        await engine.dispose()


async def test_downgrade_of_0008_is_refused_while_an_account_is_pending() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, "0008_user_deletion_grace")
    engine = create_async_engine(url)
    try:
        async with engine.begin() as conn:
            await _user(conn, deletion_requested_at="now()", erase_after="now() + interval '1 day'")
        with pytest.raises(Exception, match="pending deletion"):
            downgrade(url, "0007_sync_changes_scope")
    finally:
        await engine.dispose()


@pytest.mark.parametrize(
    "columns",
    [
        {"archived_at": "now()"},  # reason missing
        {"archive_reason": "'owner_pending_deletion'"},  # timestamp missing
        {"archived_at": "now()", "archive_reason": "'bogus'"},
        {"archived_at": "now()", "archive_reason": "'owner_erased'"},  # purge date missing
        {
            "archived_at": "now()",
            "archive_reason": "'owner_pending_deletion'",
            "archive_purge_after": "now()",
        },
    ],
)
async def test_archive_columns_are_checked(columns: dict[str, str]) -> None:
    url = await _recreate_db(DB)
    run_migrations(url, "0009_profile_archive")
    engine = create_async_engine(url)
    try:
        async with engine.connect() as conn:
            owner = await _user(conn)
            with pytest.raises(DBAPIError, match="ck_profiles_archive"):
                await _profile(conn, owner, **columns)
            await conn.rollback()
    finally:
        await engine.dispose()


async def test_only_managed_profiles_can_be_archived() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, "0009_profile_archive")
    engine = create_async_engine(url)
    try:
        async with engine.connect() as conn:
            owner = await _user(conn)
            archived = {"archived_at": "now()", "archive_reason": "'owner_pending_deletion'"}
            with pytest.raises(DBAPIError, match="ck_profiles_archive_managed"):
                await _profile(conn, owner, kind="self", **archived)
            await conn.rollback()
            owner = await _user(conn)
            await _profile(conn, owner, **archived)
    finally:
        await engine.dispose()


async def test_downgrade_of_0009_is_refused_while_a_profile_is_archived() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, "0009_profile_archive")
    engine = create_async_engine(url)
    try:
        async with engine.begin() as conn:
            owner = await _user(conn)
            await _profile(
                conn,
                owner,
                archived_at="now()",
                archive_reason="'owner_pending_deletion'",
            )
        with pytest.raises(Exception, match="archived"):
            downgrade(url, "0008_user_deletion_grace")
    finally:
        await engine.dispose()


async def test_grants_and_invites_are_refused_on_an_archived_profile() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, "0009_profile_archive")
    engine = create_async_engine(url)
    try:
        async with engine.begin() as conn:
            owner = await _user(conn)
            guardian = await _user(conn)
            profile_id = uuid.uuid4()
            await conn.execute(
                text(
                    "INSERT INTO profiles (id, owner_user_id, kind, display_name, timezone, "
                    "client_updated_at, archived_at, archive_reason) VALUES (:p, :o, 'managed', "
                    "'Ward', 'UTC', now(), now(), 'owner_pending_deletion')"
                ),
                {"p": profile_id, "o": owner},
            )
        grant = text(
            "INSERT INTO profile_grants (id, profile_id, grantee_user_id, role, "
            "disclosure_version) VALUES (:i, :p, :g, 'guardian', 1)"
        )
        invite = text(
            "INSERT INTO invites (id, profile_id, created_by_user_id, role, disclosure_version, "
            "token_hash, expires_at) VALUES (:i, :p, :o, 'viewer', 1, :h, now() + interval '1 day')"
        )
        async with engine.connect() as conn:
            with pytest.raises(DBAPIError, match="archived"):
                await conn.execute(grant, {"i": uuid.uuid4(), "p": profile_id, "g": guardian})
            await conn.rollback()
            with pytest.raises(DBAPIError, match="archived"):
                await conn.execute(
                    invite, {"i": uuid.uuid4(), "p": profile_id, "o": owner, "h": "h1"}
                )
            await conn.rollback()
    finally:
        await engine.dispose()
