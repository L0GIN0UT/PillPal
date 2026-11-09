"""Revision c0004: the reverse index search needs and the lookup's decision table."""

from __future__ import annotations

import pytest
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from tests.conftest import TEST_DATABASE_URL
from tests.helpers import downgrade, run_migrations


async def _scalar(engine: AsyncEngine, sql: str) -> object:
    async with engine.connect() as conn:
        return (await conn.execute(text(sql))).scalar()


async def test_substance_lookup_has_an_index(engine: AsyncEngine) -> None:
    # (composition_id, substance_id) is the primary key; products of a substance need the reverse.
    assert await _scalar(
        engine,
        "SELECT count(*) FROM pg_indexes WHERE schemaname = 'catalog' "
        "AND tablename = 'composition_ingredients' "
        "AND indexdef LIKE '%(substance_id)%'",
    )


async def test_decisions_reject_restricted_or_malformed_numbers_and_unknown_status(
    engine: AsyncEngine,
) -> None:
    insert = (
        "INSERT INTO catalog.gtin_link_decisions (gtin, status, decided_by) "
        "VALUES ('{g}', '{s}', 'auto')"
    )
    for gtin, status in (
        ("02000000000008", "disputed"),  # restricted number
        ("04607012345670", "disputed"),  # bad check digit
        ("04607012345677", "maybe"),  # unknown status
        ("04607012345677", "locked"),  # locked needs a product
    ):
        async with engine.begin() as conn:
            with pytest.raises(IntegrityError):
                await conn.execute(text(insert.format(g=gtin, s=status)))


async def test_up_down_up_round_trip(engine: AsyncEngine) -> None:
    del engine
    probe = create_async_engine(TEST_DATABASE_URL)
    try:
        downgrade(TEST_DATABASE_URL, "c0003_search_entries")
        try:
            assert await _scalar(probe, "SELECT to_regclass('catalog.gtin_link_decisions')") is None
            assert not await _scalar(
                probe,
                "SELECT count(*) FROM pg_indexes WHERE indexname = "
                "'composition_ingredients_substance_id'",
            )
        finally:
            run_migrations(TEST_DATABASE_URL, "head")
        assert await _scalar(probe, "SELECT to_regclass('catalog.gtin_link_decisions')") is not None
    finally:
        await probe.dispose()
