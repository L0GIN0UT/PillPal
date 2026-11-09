"""Revision c0005_consensus: the tables behind the ingest and the admin audit (ADR 0014)."""

from __future__ import annotations

import pytest
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from tests.conftest import TEST_DATABASE_URL
from tests.helpers import downgrade, run_migrations

GOOD_GTIN = "04600000000015"
RESTRICTED = "02000000000008"
PRODUCT = "00000000-0000-0000-0000-000000000001"


async def _scalar(engine: AsyncEngine, sql: str) -> object:
    async with engine.connect() as conn:
        return (await conn.execute(text(sql))).scalar()


async def test_all_consensus_tables_exist(engine: AsyncEngine) -> None:
    for table in ("gtin_link_candidates", "gtin_candidate_staging", "gtin_ingest_state"):
        assert await _scalar(engine, f"SELECT to_regclass('catalog.{table}')") is not None
    assert await _scalar(engine, "SELECT to_regclass('catalog.admin_audit')") is not None


@pytest.mark.parametrize("table", ["gtin_link_candidates", "gtin_candidate_staging"])
@pytest.mark.parametrize(
    ("region", "gtin", "count"),
    [
        ("ru", RESTRICTED, 3),  # restricted numbers can never be stored
        ("ru", "04600000000016", 3),  # bad check digit
        ("ru", GOOD_GTIN, 1),  # a single person never leaves the backend
        ("xx", GOOD_GTIN, 3),  # unknown region
    ],
)
async def test_candidates_reject_what_must_never_be_stored(
    engine: AsyncEngine, table: str, region: str, gtin: str, count: int
) -> None:
    generation = ", 1" if table == "gtin_candidate_staging" else ""
    columns = ", generation" if generation else ""
    async with engine.begin() as conn:
        with pytest.raises(IntegrityError):
            await conn.execute(
                text(
                    f"INSERT INTO catalog.{table} (region{columns}, gtin, product_id, "  # noqa: S608
                    f"confirmations) VALUES (:r{generation}, :g, :p, :c)"
                ),
                {"r": region, "g": gtin, "p": PRODUCT, "c": count},
            )


async def test_audit_rows_have_a_known_action_and_a_shareable_gtin(engine: AsyncEngine) -> None:
    insert = (
        "INSERT INTO catalog.admin_audit (admin_name, action, gtin) VALUES ('ops', '{a}', '{g}')"
    )
    for action, gtin in (("delete", GOOD_GTIN), ("reject", RESTRICTED)):
        async with engine.begin() as conn:
            with pytest.raises(IntegrityError):
                await conn.execute(text(insert.format(a=action, g=gtin)))


async def test_up_down_up_round_trip(engine: AsyncEngine) -> None:
    del engine
    probe = create_async_engine(TEST_DATABASE_URL)
    try:
        downgrade(TEST_DATABASE_URL, "c0004_search_support")
        try:
            for table in ("gtin_link_candidates", "gtin_ingest_state", "admin_audit"):
                assert await _scalar(probe, f"SELECT to_regclass('catalog.{table}')") is None
            # The decisions table belongs to c0004 and must survive.
            assert await _scalar(probe, "SELECT to_regclass('catalog.gtin_link_decisions')")
        finally:
            run_migrations(TEST_DATABASE_URL, "head")
        assert await _scalar(probe, "SELECT to_regclass('catalog.admin_audit')") is not None
    finally:
        await probe.dispose()
