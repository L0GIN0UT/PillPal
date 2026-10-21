from __future__ import annotations

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from tests.conftest import TEST_DATABASE_URL
from tests.helpers import downgrade, run_migrations

EXTENSIONS = ("pg_trgm", "unaccent")


async def _scalar(engine: AsyncEngine, sql: str) -> object:
    async with engine.connect() as conn:
        return (await conn.execute(text(sql))).scalar()


async def test_baseline_creates_extensions_and_an_immutable_unaccent(engine: AsyncEngine) -> None:
    installed = await _scalar(
        engine, "SELECT array_agg(extname ORDER BY extname) FROM pg_extension"
    )
    assert set(EXTENSIONS) <= set(installed)  # type: ignore[call-overload]
    assert await _scalar(engine, "SELECT catalog.unaccent_immutable('Café Ёж')") == "Cafe Еж"
    volatility = await _scalar(
        engine,
        "SELECT p.provolatile::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
        "WHERE n.nspname = 'catalog' AND p.proname = 'unaccent_immutable'",
    )
    assert volatility == "i"


async def test_wrapper_is_usable_in_an_index_expression(engine: AsyncEngine) -> None:
    # PostgreSQL refuses non-IMMUTABLE functions in index expressions; this is what 4.3 needs.
    async with engine.begin() as conn:
        await conn.execute(text("CREATE TEMP TABLE probe (norm text) ON COMMIT DROP"))
        await conn.execute(
            text(
                "CREATE INDEX probe_trgm ON probe USING gin "
                "((lower(catalog.unaccent_immutable(norm))) gin_trgm_ops)"
            )
        )


async def test_up_down_up_round_trip(engine: AsyncEngine) -> None:
    del engine  # requested only so that the schema is migrated before the round trip
    probe = create_async_engine(TEST_DATABASE_URL)
    try:
        downgrade(TEST_DATABASE_URL, "base")
        try:
            assert await _scalar(probe, "SELECT to_regnamespace('catalog')") is None
            left = await _scalar(
                probe, "SELECT count(*) FROM pg_extension WHERE extname IN ('pg_trgm', 'unaccent')"
            )
            assert left == 0
        finally:
            run_migrations(TEST_DATABASE_URL, "head")
        assert await _scalar(probe, "SELECT catalog.unaccent_immutable('é')") == "e"
    finally:
        await probe.dispose()
