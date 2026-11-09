"""Schema contract of revisions c0002 and c0003: the constraints live in PostgreSQL."""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from catalog.db import models
from tests.conftest import TEST_DATABASE_URL
from tests.helpers import downgrade, run_migrations
from tests.importers.support import SEEDED_SOURCES

SOURCE = "rxnorm"
DIGEST = "a" * 64
INSERT_RUN = (
    "INSERT INTO catalog.import_runs (id, source, snapshot_sha256, status, finished_at) "
    "VALUES (:id, :s, :h, :st, CASE WHEN :st = 'running' THEN NULL ELSE now() END)"
)


async def _exec(engine: AsyncEngine, sql: str, **params: object) -> None:
    async with engine.begin() as conn:
        await conn.execute(text(sql), params)


async def _scalar(engine: AsyncEngine, sql: str, **params: object) -> object:
    async with engine.connect() as conn:
        return (await conn.execute(text(sql), params)).scalar()


async def _run(engine: AsyncEngine, source: str = SOURCE, status: str = "succeeded") -> uuid.UUID:
    run = uuid.uuid4()
    await _exec(engine, INSERT_RUN, id=run, s=source, h=DIGEST, st=status)
    return run


async def test_sources_are_seeded_once(engine: AsyncEngine) -> None:
    codes = await _scalar(engine, "SELECT array_agg(code ORDER BY code) FROM catalog.sources")
    assert set(SEEDED_SOURCES) <= set(codes)  # type: ignore[call-overload]
    disabled = await _scalar(
        engine, "SELECT array_agg(code ORDER BY code) FROM catalog.sources WHERE NOT enabled"
    )
    assert {"esklp", "grls_manual"} <= set(disabled)  # type: ignore[call-overload]


async def test_models_describe_exactly_the_migrated_columns(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        rows = (
            await conn.execute(
                text(
                    "SELECT table_name, column_name FROM information_schema.columns "
                    "WHERE table_schema = 'catalog'"
                )
            )
        ).all()
    in_db: dict[str, set[str]] = {}
    for table, column in rows:
        in_db.setdefault(table, set()).add(column)
    in_models = {t.name: {c.name for c in t.columns} for t in models.Base.metadata.sorted_tables}
    assert in_models == in_db


async def test_second_running_import_of_a_source_is_refused(
    engine: AsyncEngine, clean_catalog: None
) -> None:
    await _run(engine, status="running")
    with pytest.raises(IntegrityError):
        await _run(engine, status="running")
    # Another source and a finished run do not collide.
    await _run(engine, source="openfda_ndc", status="running")
    await _run(engine, status="succeeded")
    await _run(engine, status="failed")


async def _substance(engine: AsyncEngine, run: uuid.UUID) -> uuid.UUID:
    sid = uuid.uuid4()
    await _exec(
        engine,
        "INSERT INTO catalog.substances (id, source, source_key, market, name_en, last_run_id) "
        "VALUES (:id, :s, 'k', 'us', 'Testamol', :r)",
        id=sid,
        s=SOURCE,
        r=run,
    )
    return sid


async def _composition(
    engine: AsyncEngine,
    run: uuid.UUID,
    key: str = "c",
    form: str | None = "TAB",
    complete: bool = False,
) -> uuid.UUID:
    cid = uuid.uuid4()
    await _exec(
        engine,
        "INSERT INTO catalog.compositions (id, source, source_key, market, form_code, complete, "
        "identity_key, last_run_id) VALUES (:id, :s, :k, 'us', :f, :c, :i, :r)",
        id=cid,
        s=SOURCE,
        k=key,
        f=form,
        c=complete,
        i="c" * 64,
        r=run,
    )
    return cid


async def test_complete_composition_requires_a_form(
    engine: AsyncEngine, clean_catalog: None
) -> None:
    run = await _run(engine)
    with pytest.raises(IntegrityError):
        await _composition(engine, run, form=None, complete=True)
    await _composition(engine, run, form=None, complete=False)


async def test_composition_identity_is_unique_within_a_source(
    engine: AsyncEngine, clean_catalog: None
) -> None:
    run = await _run(engine)
    await _composition(engine, run, key="one")
    with pytest.raises(IntegrityError):
        await _composition(engine, run, key="two")  # same identity_key, same source


@pytest.mark.parametrize(
    "values",
    [
        "500, NULL, NULL, NULL",  # a strength needs a unit
        "NULL, 'mg', NULL, NULL",  # a unit needs a strength
        "0, 'mg', NULL, NULL",  # strength must be positive
        "-1, 'mg', NULL, NULL",
        "5, 'mg', 0, 'mL'",  # per value must be positive
        "5, 'mg', 5, NULL",  # per value needs a per unit
    ],
)
async def test_ingredient_strength_checks(
    engine: AsyncEngine, clean_catalog: None, values: str
) -> None:
    run = await _run(engine)
    sid = await _substance(engine, run)
    cid = await _composition(engine, run)
    insert = (
        "INSERT INTO catalog.composition_ingredients (composition_id, substance_id, "
        "strength_value, strength_unit, per_value, per_unit) VALUES (:c, :s, {})"
    )
    await _exec(engine, insert.format("500, 'mg', NULL, NULL"), c=cid, s=sid)  # valid shape
    await _exec(engine, "DELETE FROM catalog.composition_ingredients")
    with pytest.raises(IntegrityError):
        await _exec(engine, insert.format(values), c=cid, s=sid)


async def test_product_market_is_one_of_the_known_markets(
    engine: AsyncEngine, clean_catalog: None
) -> None:
    run = await _run(engine)
    insert = (
        "INSERT INTO catalog.products (id, source, source_key, market, brand_name, last_run_id) "
        "VALUES (:id, :s, :k, :m, 'Testamol 500', :r)"
    )
    await _exec(engine, insert, id=uuid.uuid4(), s=SOURCE, k="a", m="us", r=run)
    with pytest.raises(IntegrityError):
        await _exec(engine, insert, id=uuid.uuid4(), s=SOURCE, k="b", m="xx", r=run)


async def test_a_product_with_a_registration_number_keeps_it(
    engine: AsyncEngine, clean_catalog: None
) -> None:
    run = await _run(engine)
    await _exec(
        engine,
        "INSERT INTO catalog.products (id, source, source_key, market, brand_name, "
        "registration_number, last_run_id) "
        "VALUES (:id, :s, 'a', 'ru', 'Testamol 500', 'TST-1', :r)",
        id=uuid.uuid4(),
        s=SOURCE,
        r=run,
    )
    await _exec(
        engine,
        "INSERT INTO catalog.recall_flags (registration_number, series, reason_code, source) "
        "VALUES ('TST-1', 'S1', 'rejected', 'ru_roszdravnadzor')",
    )
    joined = await _scalar(
        engine,
        "SELECT count(*) FROM catalog.recall_flags f JOIN catalog.products p "
        "ON p.registration_number = f.registration_number",
    )
    assert joined == 1
    await _exec(engine, "DELETE FROM catalog.recall_flags")


async def test_search_entries_are_normalised_by_the_database(
    engine: AsyncEngine, clean_catalog: None
) -> None:
    entity = uuid.uuid4()
    await _exec(
        engine,
        "INSERT INTO catalog.search_entries (entity_kind, entity_id, market, lang, text) "
        "VALUES ('product', :e, 'ru', 'ru', 'ТЁСТАМОЛ Café')",
        e=entity,
    )
    norm = await _scalar(
        engine, "SELECT norm FROM catalog.search_entries WHERE entity_id = :e", e=entity
    )
    assert norm == "тестамол cafe"
    exact = await _scalar(
        engine,
        "SELECT count(*) FROM catalog.search_entries "
        "WHERE tsv @@ plainto_tsquery('simple', catalog.search_norm('тестамол'))",
    )
    assert exact == 1
    typo = await _scalar(
        engine, "SELECT count(*) FROM catalog.search_entries WHERE norm % 'тестамл'"
    )
    assert typo == 1


async def test_search_entries_have_the_gin_indexes(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        definitions = (
            (
                await conn.execute(
                    text(
                        "SELECT indexdef FROM pg_indexes "
                        "WHERE schemaname = 'catalog' AND tablename = 'search_entries'"
                    )
                )
            )
            .scalars()
            .all()
        )
    joined = " ".join(definitions)
    assert "USING gin (tsv)" in joined
    assert "gin_trgm_ops" in joined


async def test_downgrade_to_the_baseline_removes_the_tables_and_upgrade_restores_them(
    engine: AsyncEngine,
) -> None:
    del engine  # requested only so that the schema is migrated first
    probe = create_async_engine(TEST_DATABASE_URL)
    try:
        downgrade(TEST_DATABASE_URL, "c0001_baseline")
        try:
            assert await _scalar(probe, "SELECT to_regclass('catalog.sources')") is None
            assert await _scalar(probe, "SELECT to_regclass('catalog.search_entries')") is None
            assert await _scalar(probe, "SELECT to_regproc('catalog.gtin_is_shareable')") is None
            assert await _scalar(probe, "SELECT to_regproc('catalog.search_norm')") is None
        finally:
            run_migrations(TEST_DATABASE_URL, "head")
        count = await _scalar(probe, "SELECT count(*) FROM catalog.sources")
        assert count == len(SEEDED_SOURCES)
    finally:
        await probe.dispose()
