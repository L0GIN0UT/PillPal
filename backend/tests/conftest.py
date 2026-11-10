"""Shared fixtures for API tests.

Integration tests run against a real PostgreSQL database (migrated with Alembic
at session start) and a real Redis. Only fixtures that need them touch them, so
pure unit tests (e.g. tests/domain/**) run without any services.
"""

from __future__ import annotations

import asyncio
import base64
import os
from collections.abc import AsyncIterator, Callable, Iterator
from contextlib import AbstractAsyncContextManager, asynccontextmanager
from datetime import UTC, datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from pydantic import SecretStr
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.config import Settings, normalize_database_url
from app.deps import get_now
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

# Two keys of the data encryption keyring (rotation tests use both); the export flag is off by
# default and the ``export_on`` fixture switches it on.
EXPORT_KEY_1 = base64.b64encode(bytes(range(32))).decode()
EXPORT_KEY_2 = base64.b64encode(bytes(range(32, 64))).decode()

TABLES = (
    "data_exports",
    "admin_audit",
    "promo_redemptions",
    "promo_codes",
    "entitlements",
    "consents",
    "push_outbox",
    "missed_dose_alerts",
    "push_tokens",
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
        "data_encryption_keys": {1: EXPORT_KEY_1, 2: EXPORT_KEY_2},
        "data_encryption_key_id": 1,
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


class FakeClock:
    """Injected ``now`` for endpoints that take the clock (``app.deps.get_now``)."""

    def __init__(self) -> None:
        self.now = datetime.now(UTC)

    def __call__(self) -> datetime:
        return self.now

    def advance(self, **delta: float) -> None:
        self.now += timedelta(**delta)


@pytest.fixture
def clock(app_and_engine: tuple[object, AsyncEngine]) -> Iterator[FakeClock]:
    app = app_and_engine[0]
    fake = FakeClock()
    app.dependency_overrides[get_now] = fake  # type: ignore[attr-defined]
    yield fake
    app.dependency_overrides.pop(get_now, None)  # type: ignore[attr-defined]


@pytest.fixture
def disclosure_versions(monkeypatch: pytest.MonkeyPatch, settings: Settings) -> list[int]:
    """Pretend newer disclosure screens exist (the default accepts version 1 only)."""
    versions = [1, 2, 3, 4, 7]
    monkeypatch.setattr(settings, "supported_disclosure_versions", versions)
    return versions


@pytest.fixture
def contributions_on(monkeypatch: pytest.MonkeyPatch, settings: Settings) -> None:
    """Catalog contributions are off by default; consent grants are refused until they are on."""
    monkeypatch.setattr(settings, "catalog_contributions_enabled", True)


@pytest.fixture
def promo_on(monkeypatch: pytest.MonkeyPatch, settings: Settings) -> Settings:
    """Promo codes are off by default; turn them on with the test key (the settings object is
    the one the app reads, so the change is undone after the test)."""
    from tests.promo_helpers import KEY_B64

    monkeypatch.setattr(settings, "promo_code_hmac_key", SecretStr(KEY_B64))
    monkeypatch.setattr(settings, "feature_promo_codes", True)
    return settings


@pytest.fixture
def redis_outage(
    app_and_engine: tuple[object, AsyncEngine],
) -> Callable[[], AbstractAsyncContextManager[None]]:
    """``async with redis_outage():`` makes the app's Redis unreachable inside the block (after
    the test's own setup, which needs it). The attribute is restored by hand:
    ``monkeypatch.setattr`` on Starlette's ``State`` deletes it on undo (it has no real
    attribute to restore), which broke every later test."""
    state = app_and_engine[0].state  # type: ignore[attr-defined]

    @asynccontextmanager
    async def outage() -> AsyncIterator[None]:
        live = state.redis
        dead: Redis = Redis.from_url(
            "redis://127.0.0.1:1/0", socket_connect_timeout=0.2, socket_timeout=0.2
        )
        state.redis = dead
        try:
            yield
        finally:
            state.redis = live
            await dead.aclose()

    return outage


@pytest.fixture
def export_on(monkeypatch: pytest.MonkeyPatch, settings: Settings) -> None:
    """The data export is off by default; its endpoints answer 403 until it is on."""
    monkeypatch.setattr(settings, "feature_data_export", True)


@pytest.fixture
def maker(
    app_and_engine: tuple[object, AsyncEngine], clean_state: None
) -> async_sessionmaker[AsyncSession]:
    """The app's session factory, for jobs and services called directly."""
    return app_and_engine[0].state.sessionmaker  # type: ignore[attr-defined,no-any-return]


@pytest.fixture
def now() -> FakeClock:
    """An injected clock for jobs. Rows are inserted with the database's ``now()``, so it starts
    a few seconds later: they are already due, and nothing is stale."""
    clock = FakeClock()
    clock.advance(seconds=5)
    return clock
