"""Fixtures of the public API tests: an empty catalog per test and a seeding helper."""

from __future__ import annotations

from collections.abc import AsyncIterator

import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.api.seed import Seed
from tests.importers.support import wipe_catalog


async def _wipe(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        # Decisions reference products; the shared wipe knows nothing about them.
        await conn.execute(text("DELETE FROM catalog.gtin_link_decisions"))
    await wipe_catalog(engine)


@pytest_asyncio.fixture
async def seed(engine: AsyncEngine) -> AsyncIterator[Seed]:
    await _wipe(engine)
    yield Seed(engine)
    await _wipe(engine)
