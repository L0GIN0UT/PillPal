"""Shared fixtures for API tests.

Integration tests run against a real PostgreSQL database (migrated with Alembic
at session start) and a real Redis. Only fixtures that need them touch them, so
pure unit tests (e.g. tests/domain/**) run without any services.
"""

from __future__ import annotations

import asyncio
import os
from collections.abc import AsyncIterator

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from app.config import Settings, normalize_database_url
from app.email import InMemoryEmailSender
from app.main import create_app
from tests.helpers import run_migrations, run_sync

TEST_DATABASE_URL = normalize_database_url(
    os.environ.get(
        "TEST_DATABASE_URL",
        os.environ.get(
            "DATABASE_URL", "postgresql+asyncpg://postgres:postgres@localhost:5432/pillpal_test"
        ),
    )
)
TEST_REDIS_URL = os.environ.get(
    "TEST_REDIS_URL", os.environ.get("REDIS_URL", "redis://localhost:6379/15")
)

TABLES = (
    "invites",
    "profile_grants",
    "sync_changes",
    "dose_events",
    "schedules",
    "medications",
    "profiles",
    "email_codes",
    "refresh_tokens",
    "devices",
    "users",
)


def make_settings(**overrides: object) -> Settings:
    values: dict[str, object] = {
        "region": "ru",
        "database_url": TEST_DATABASE_URL,
        "redis_url": TEST_REDIS_URL,
        "jwt_secret": "test-secret-test-secret-test-secret-0123",
        "rate_limit_auth_max_attempts": 20,
        "environment": "test",
        "log_level": "INFO",
        # Cheap Argon2id parameters keep the suite fast; production uses defaults.
        "password_hash_time_cost": 1,
        "password_hash_memory_kib": 1024,
        "password_hash_parallelism": 1,
    }
    values.update(overrides)
    return Settings.model_validate(values)


@pytest.fixture(scope="session")
def settings() -> Settings:
    return make_settings()


@pytest.fixture(scope="session")
def migrated_db() -> str:
    """Reset the test database schema and run all Alembic migrations once."""
    run_sync(asyncio.run, _reset_schema(TEST_DATABASE_URL))
    run_migrations(TEST_DATABASE_URL, "head")
    return TEST_DATABASE_URL


async def _reset_schema(url: str) -> None:
    engine = create_async_engine(url)
    async with engine.begin() as conn:
        await conn.execute(text("DROP SCHEMA IF EXISTS public CASCADE"))
        await conn.execute(text("CREATE SCHEMA public"))
    await engine.dispose()


@pytest.fixture(scope="session")
def email_sender() -> InMemoryEmailSender:
    return InMemoryEmailSender()


@pytest_asyncio.fixture(scope="session")
async def app_and_engine(
    migrated_db: str, settings: Settings, email_sender: InMemoryEmailSender
) -> AsyncIterator[tuple[object, AsyncEngine]]:
    app = create_app(settings, email_sender=email_sender)
    async with app.router.lifespan_context(app):
        yield app, app.state.engine


@pytest_asyncio.fixture
async def clean_state(
    app_and_engine: tuple[object, AsyncEngine], email_sender: InMemoryEmailSender
) -> None:
    _, engine = app_and_engine
    async with engine.begin() as conn:
        await conn.execute(text(f"TRUNCATE {', '.join(TABLES)} RESTART IDENTITY CASCADE"))
    redis: Redis = Redis.from_url(TEST_REDIS_URL)
    await redis.flushdb()
    await redis.aclose()
    email_sender.outbox.clear()


@pytest_asyncio.fixture
async def client(
    app_and_engine: tuple[object, AsyncEngine], clean_state: None
) -> AsyncIterator[AsyncClient]:
    app, _ = app_and_engine
    transport = ASGITransport(app=app, raise_app_exceptions=False)  # type: ignore[arg-type]
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest_asyncio.fixture
async def engine(app_and_engine: tuple[object, AsyncEngine], clean_state: None) -> AsyncEngine:
    return app_and_engine[1]
