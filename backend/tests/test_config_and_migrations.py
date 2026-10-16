"""Settings validation and Alembic migrations vs. ORM models."""

from __future__ import annotations

import asyncio
from typing import Any

import pytest
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from pydantic import ValidationError
from sqlalchemy import Connection, text
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from app.config import Settings, normalize_database_url
from app.db.base import Base
from tests.conftest import TEST_DATABASE_URL, make_settings
from tests.helpers import downgrade, run_migrations, run_sync


def test_region_is_required(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("REGION", raising=False)
    with pytest.raises(ValidationError):
        Settings(jwt_secret="x" * 32)  # type: ignore[call-arg]


def test_region_must_be_known() -> None:
    with pytest.raises(ValidationError):
        make_settings(region="us")


def test_jwt_secret_must_be_long() -> None:
    with pytest.raises(ValidationError):
        make_settings(jwt_secret="short")


def test_settings_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("REGION", "eu")
    monkeypatch.setenv("JWT_SECRET", "e" * 40)
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@db:5432/pillpal")
    monkeypatch.setenv("CORS_ORIGINS", '["https://a.example"]')
    s = Settings()  # type: ignore[call-arg]
    assert s.region == "eu"
    assert s.access_token_ttl_seconds == 15 * 60
    assert s.database_url == "postgresql+asyncpg://u:p@db:5432/pillpal"
    assert s.cors_origins == ["https://a.example"]


def test_cors_off_by_default() -> None:
    assert make_settings().cors_origins == []


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("postgresql://a/b", "postgresql+asyncpg://a/b"),
        ("postgres://a/b", "postgresql+asyncpg://a/b"),
        ("postgresql+asyncpg://a/b", "postgresql+asyncpg://a/b"),
    ],
)
def test_normalize_database_url(raw: str, expected: str) -> None:
    assert normalize_database_url(raw) == expected


def _diff(conn: Connection) -> list[Any]:
    ctx = MigrationContext.configure(conn, opts={"compare_type": True})
    return list(compare_metadata(ctx, Base.metadata))


async def test_migrations_match_models(migrated_db: str) -> None:
    engine = create_async_engine(migrated_db)
    async with engine.connect() as conn:
        diff = await conn.run_sync(_diff)
    await engine.dispose()
    assert diff == []


async def _recreate_db(name: str) -> str:
    admin = create_async_engine(
        TEST_DATABASE_URL.rsplit("/", 1)[0] + "/postgres", isolation_level="AUTOCOMMIT"
    )
    async with admin.connect() as conn:
        await conn.execute(text(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)'))
        await conn.execute(text(f'CREATE DATABASE "{name}"'))
    await admin.dispose()
    return TEST_DATABASE_URL.rsplit("/", 1)[0] + f"/{name}"


async def _tables(engine: AsyncEngine) -> set[str]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT tablename FROM pg_tables WHERE schemaname = 'public'")
        )
        return {r[0] for r in rows}


async def test_migrations_roundtrip_upgrade_downgrade_upgrade() -> None:
    url = await _recreate_db("pillpal_test_migrations")
    run_migrations(url, "head")
    engine = create_async_engine(url)
    assert "sync_changes" in await _tables(engine)
    downgrade(url, "base")
    assert await _tables(engine) <= {"alembic_version"}
    run_migrations(url, "head")
    assert "users" in await _tables(engine)
    await engine.dispose()


async def test_schema_constraints_are_enforced(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        with pytest.raises(Exception, match="check"):
            await conn.execute(
                text(
                    "INSERT INTO users (id, email, password_hash, region, locale) "
                    "VALUES (gen_random_uuid(), 'a@b.c', 'x', 'us', 'en')"
                )
            )
        await conn.rollback()
        await conn.execute(
            text(
                "INSERT INTO users (id, email, password_hash, region, locale) "
                "VALUES (gen_random_uuid(), 'Dup@b.c', 'x', 'ru', 'en')"
            )
        )
        with pytest.raises(Exception, match="unique"):
            await conn.execute(
                text(
                    "INSERT INTO users (id, email, password_hash, region, locale) "
                    "VALUES (gen_random_uuid(), 'dup@B.C', 'x', 'ru', 'en')"
                )
            )
        await conn.rollback()


async def test_expected_indexes_exist(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT indexdef FROM pg_indexes WHERE schemaname = 'public'")
        )
        defs = [r[0] for r in rows]
    assert any("sync_changes" in d and "(user_id, seq)" in d for d in defs)
    assert any("dose_events" in d and "(profile_id, occurrence_key)" in d for d in defs)
    assert any("users" in d and "lower(email" in d and "UNIQUE" in d for d in defs)
    # Every FK column is indexed.
    for table, column in [
        ("profiles", "owner_user_id"),
        ("medications", "profile_id"),
        ("schedules", "medication_id"),
        ("dose_events", "medication_id"),
        ("dose_events", "target_event_id"),
        ("refresh_tokens", "user_id"),
        ("email_codes", "user_id"),
        ("devices", "user_id"),
    ]:
        assert any(f"ON public.{table} " in d and f"({column}" in d for d in defs), (table, column)


def test_run_sync_helper_works() -> None:
    assert run_sync(asyncio.run, asyncio.sleep(0, result=7)) == 7
