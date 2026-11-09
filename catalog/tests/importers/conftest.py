"""Fixtures for tests that write catalog rows: a clean content state per test."""

from __future__ import annotations

from collections.abc import AsyncIterator

import pytest_asyncio
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from catalog.db.session import create_sessionmaker
from tests.importers.support import wipe_catalog


@pytest_asyncio.fixture
async def clean_catalog(engine: AsyncEngine) -> AsyncIterator[None]:
    await wipe_catalog(engine)
    yield
    await wipe_catalog(engine)


@pytest_asyncio.fixture
async def sessionmaker(
    engine: AsyncEngine, clean_catalog: None
) -> async_sessionmaker[AsyncSession]:
    return create_sessionmaker(engine)
