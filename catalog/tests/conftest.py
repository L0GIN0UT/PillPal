"""Shared fixtures. Integration tests run on a real PostgreSQL database (migrated with Alembic once
per session) and a real Redis; pure unit tests do not touch either."""

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

from catalog.config import Settings, normalize_database_url
from catalog.main import create_app
from tests.helpers import run_migrations, run_sync

TEST_DATABASE_URL = normalize_database_url(
    os.environ.get(
        "TEST_CATALOG_DATABASE_URL",
        os.environ.get(
            "CATALOG_DATABASE_URL",
            "postgresql+asyncpg://postgres:postgres@localhost:5432/pillpal_catalog_test",
        ),
    )
)
TEST_REDIS_URL = os.environ.get(
    "TEST_CATALOG_REDIS_URL", os.environ.get("CATALOG_REDIS_URL", "redis://localhost:6379/3")
)


def make_settings(**overrides: object) -> Settings:
    values: dict[str, object] = {
        "database_url": TEST_DATABASE_URL,
        "redis_url": TEST_REDIS_URL,
        "environment": "test",
        "rate_limit_salt": "test-salt-test-salt",
    }
    values.update(overrides)
    return Settings.model_validate(values)


@pytest.fixture(scope="session")
def settings() -> Settings:
    return make_settings()


async def reset_schemas(url: str) -> None:
    engine = create_async_engine(url)
    async with engine.begin() as conn:
        await conn.execute(text("DROP SCHEMA IF EXISTS catalog CASCADE"))
        await conn.execute(text("DROP SCHEMA IF EXISTS public CASCADE"))
        await conn.execute(text("CREATE SCHEMA public"))
    await engine.dispose()


@pytest.fixture(scope="session")
def migrated_db() -> str:
    """Reset the test database and run all Alembic migrations once."""
    run_sync(asyncio.run, reset_schemas(TEST_DATABASE_URL))
    run_migrations(TEST_DATABASE_URL, "head")
    return TEST_DATABASE_URL


@pytest_asyncio.fixture(scope="session")
async def app_and_engine(
    migrated_db: str, settings: Settings
) -> AsyncIterator[tuple[object, AsyncEngine]]:
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        yield app, app.state.engine


@pytest_asyncio.fixture
async def clean_redis() -> None:
    redis: Redis = Redis.from_url(TEST_REDIS_URL)
    await redis.flushdb()
    await redis.aclose()


@pytest_asyncio.fixture
async def client(
    app_and_engine: tuple[object, AsyncEngine], clean_redis: None
) -> AsyncIterator[AsyncClient]:
    app, _ = app_and_engine
    transport = ASGITransport(app=app, raise_app_exceptions=False)  # type: ignore[arg-type]
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest_asyncio.fixture
async def engine(app_and_engine: tuple[object, AsyncEngine]) -> AsyncEngine:
    return app_and_engine[1]
