"""Revisions 0010 (push_tokens) and 0011 (push_outbox): round trips and CHECKs."""

from __future__ import annotations

import json
import uuid
from typing import Any

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError, IntegrityError
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, create_async_engine

from tests.helpers import downgrade, run_migrations
from tests.test_config_and_migrations import _recreate_db, _tables

DB = "pillpal_test_push_migrations"
STEPS = [
    ("0009_profile_archive", "0010_push_tokens", "push_tokens"),
    ("0010_push_tokens", "0011_push_outbox", "push_outbox"),
]
APNS_TOKEN = "ab" * 32
ALERT, PROFILE = str(uuid.uuid4()), str(uuid.uuid4())


@pytest.mark.parametrize(("before", "revision", "table"), STEPS)
async def test_revision_round_trips(before: str, revision: str, table: str) -> None:
    url = await _recreate_db(DB)
    run_migrations(url, before)
    engine = create_async_engine(url)
    try:
        assert table not in await _tables(engine)
        run_migrations(url, revision)
        assert table in await _tables(engine)
        downgrade(url, before)
        assert table not in await _tables(engine)
        run_migrations(url, revision)
        assert table in await _tables(engine)
    finally:
        await engine.dispose()


def test_revision_ids_fit_alembic_version_column() -> None:
    assert all(len(rev) <= 32 for _, rev, _ in STEPS)


async def _seed(conn: AsyncConnection) -> tuple[uuid.UUID, uuid.UUID]:
    user_id = uuid.uuid4()
    await conn.execute(
        text(
            "INSERT INTO users (id, email, password_hash, region) VALUES (:id, :email, 'x', 'ru')"
        ),
        {"id": user_id, "email": f"{user_id.hex[:8]}@example.com"},
    )
    await conn.execute(
        text(
            "INSERT INTO devices (id, user_id, device_id) VALUES (gen_random_uuid(), :u, 'dev-1')"
        ),
        {"u": user_id},
    )
    profile_id = uuid.uuid4()
    await conn.execute(
        text(
            "INSERT INTO profiles (id, owner_user_id, kind, display_name, timezone, "
            "client_updated_at) VALUES (:p, :u, 'self', 'Me', 'UTC', now())"
        ),
        {"p": profile_id, "u": user_id},
    )
    return user_id, profile_id


async def _token(conn: AsyncConnection, user_id: uuid.UUID, **overrides: Any) -> uuid.UUID:
    values: dict[str, Any] = {
        "id": uuid.uuid4(),
        "u": user_id,
        "d": "dev-1",
        "provider": "fcm",
        "token": "tok_ABC:def-1",
        "env": None,
    }
    values.update(overrides)
    await conn.execute(
        text(
            "INSERT INTO push_tokens (id, user_id, device_id, provider, token, apns_environment) "
            "VALUES (:id, :u, :d, :provider, :token, :env)"
        ),
        values,
    )
    return values["id"]  # type: ignore[no-any-return]


@pytest.fixture
async def migrated_engine() -> AsyncEngine:
    url = await _recreate_db(DB)
    run_migrations(url, "head")
    engine = create_async_engine(url)
    yield engine  # type: ignore[misc]
    await engine.dispose()


@pytest.mark.parametrize(
    "overrides",
    [
        {"provider": "webpush"},
        {"provider": "apns", "token": "AB" * 32, "env": "sandbox"},  # upper-case hex
        {"provider": "apns", "token": "ab" * 31, "env": "sandbox"},  # too short
        {"provider": "apns", "token": "ab" * 101, "env": "sandbox"},  # too long
        {"provider": "apns", "token": APNS_TOKEN},  # environment missing
        {"provider": "fcm", "env": "sandbox"},  # environment on a non-APNs token
        {"provider": "apns", "token": APNS_TOKEN, "env": "staging"},
        {"token": "has space"},
        {"token": "../etc"},
        {"token": ""},
        {"token": "a" * 4097},
        {"provider": "rustore", "token": "a/b"},
    ],
)
async def test_token_checks(migrated_engine: AsyncEngine, overrides: dict[str, Any]) -> None:
    async with migrated_engine.connect() as conn:
        user_id, _ = await _seed(conn)
        with pytest.raises(IntegrityError, match="ck_push_tokens"):
            await _token(conn, user_id, **overrides)


async def test_valid_tokens_and_uniqueness(migrated_engine: AsyncEngine) -> None:
    async with migrated_engine.begin() as conn:
        user_id, _ = await _seed(conn)
        await _token(conn, user_id)
        await conn.execute(
            text(
                "INSERT INTO devices (id, user_id, device_id) VALUES (gen_random_uuid(), :u, 'd2')"
            ),
            {"u": user_id},
        )
        await _token(conn, user_id, d="d2", provider="apns", token=APNS_TOKEN, env="production")
    async with migrated_engine.connect() as conn:
        user_id = (await conn.execute(text("SELECT id FROM users"))).scalar_one()
        await conn.execute(
            text(
                "INSERT INTO devices (id, user_id, device_id) VALUES (gen_random_uuid(), :u, 'd3')"
            ),
            {"u": user_id},
        )
        with pytest.raises(IntegrityError, match="uq_push_tokens_provider_token"):
            await _token(conn, user_id, d="d3")  # the default token is already registered
        await conn.rollback()
        with pytest.raises(IntegrityError, match="uq_push_tokens_user_id_device_id"):
            await _token(conn, user_id, token="another")


async def test_token_needs_a_device_and_goes_with_it(migrated_engine: AsyncEngine) -> None:
    async with migrated_engine.connect() as conn:
        user_id, _ = await _seed(conn)
        with pytest.raises(IntegrityError, match="fk_push_tokens"):
            await _token(conn, user_id, d="never-seen")
        await conn.rollback()
    async with migrated_engine.begin() as conn:
        user_id, _ = await _seed(conn)
        await _token(conn, user_id)
        await conn.execute(text("DELETE FROM devices"))
        count = (await conn.execute(text("SELECT count(*) FROM push_tokens"))).scalar_one()
        assert count == 0


async def _outbox(
    conn: AsyncConnection, token_id: uuid.UUID, user_id: uuid.UUID, **overrides: Any
) -> None:
    values: dict[str, Any] = {
        "tid": token_id,
        "u": user_id,
        "kind": "missed",
        "dedupe": f"missed:{uuid.uuid4()}",
        "payload": json.dumps({"v": 1, "t": "missed", "a": ALERT, "p": PROFILE}),
        "status": "pending",
        "attempts": 0,
    }
    values.update(overrides)
    await conn.execute(
        text(
            "INSERT INTO push_outbox (push_token_id, recipient_user_id, kind, dedupe_key, "
            "payload, status, attempts, sent_at) VALUES (:tid, :u, :kind, :dedupe, "
            "CAST(:payload AS jsonb), :status, :attempts, "
            "CASE WHEN :status = 'sent' THEN now() END)"
        ),
        values,
    )


@pytest.mark.parametrize(
    "overrides",
    [
        {"payload": json.dumps({"v": 1, "t": "missed", "a": ALERT, "p": PROFILE, "name": "x"})},
        {"payload": json.dumps({"v": 1, "t": "missed", "a": ALERT, "p": PROFILE, "note": "x"})},
        {"payload": json.dumps({"v": 1, "t": "missed", "a": "Aspirin 100 mg", "p": PROFILE})},
        {"payload": json.dumps({"v": 1, "t": "missed", "a": ALERT, "p": PROFILE, "s": "x"})},
        {"payload": json.dumps({"v": 2, "t": "missed", "a": ALERT, "p": PROFILE})},
        {"payload": json.dumps([1, 2])},
        {"payload": json.dumps({"v": 1, "t": "resolved", "a": ALERT, "p": PROFILE})},  # t != kind
        {"kind": "taken", "payload": json.dumps({"v": 1, "t": "taken", "a": ALERT, "p": PROFILE})},
        {"status": "queued"},
        {"attempts": -1},
    ],
)
async def test_outbox_checks(migrated_engine: AsyncEngine, overrides: dict[str, Any]) -> None:
    async with migrated_engine.connect() as conn:
        user_id, _ = await _seed(conn)
        token_id = await _token(conn, user_id)
        with pytest.raises(IntegrityError, match="ck_push_outbox"):
            await _outbox(conn, token_id, user_id, **overrides)


async def test_outbox_dedupe_and_cascades(migrated_engine: AsyncEngine) -> None:
    async with migrated_engine.begin() as conn:
        user_id, _ = await _seed(conn)
        token_id = await _token(conn, user_id)
        await _outbox(conn, token_id, user_id, dedupe="missed:1")
        await _outbox(conn, token_id, user_id, status="sent", dedupe="missed:2")
    async with migrated_engine.connect() as conn:
        user_id = (await conn.execute(text("SELECT id FROM users"))).scalar_one()
        token_id = (await conn.execute(text("SELECT id FROM push_tokens"))).scalar_one()
        with pytest.raises(IntegrityError, match="uq_push_outbox_dedupe_key"):
            await _outbox(conn, token_id, user_id, dedupe="missed:1")
        await conn.rollback()
        # A sent row must record when; a pending one must not.
        with pytest.raises((IntegrityError, DBAPIError), match="ck_push_outbox"):
            await conn.execute(
                text("UPDATE push_outbox SET sent_at = NULL WHERE dedupe_key = 'missed:2'")
            )
        await conn.rollback()
        await conn.execute(text("DELETE FROM push_tokens"))
        assert (await conn.execute(text("SELECT count(*) FROM push_outbox"))).scalar_one() == 0


async def test_pending_index_exists(migrated_engine: AsyncEngine) -> None:
    async with migrated_engine.connect() as conn:
        definition = (
            await conn.execute(
                text("SELECT indexdef FROM pg_indexes WHERE indexname = 'ix_push_outbox_pending'")
            )
        ).scalar_one()
    assert "next_attempt_at" in definition
    assert "pending" in definition
