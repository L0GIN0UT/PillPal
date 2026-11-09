"""The shared loader: staging, upsert by deterministic id, withdraw, search entries, one
transaction per run. Real PostgreSQL; the only fake is the synthetic fixture importer."""

from __future__ import annotations

import uuid
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from catalog.domain.identity import IngredientKey, composition_identity_key, entity_id
from catalog.importers.base import ImporterDataError, ImporterError
from catalog.importers.fixture import FixtureImporter, ensure_dev_source
from catalog.importers.loader import ImportInProgress, run_import
from tests.importers.support import DATA_TABLES, V1, V2, dump, mutated_snapshot, rows

Sessions = async_sessionmaker[AsyncSession]
RESTRICTED_AND_BAD_CHECK_DIGIT = 2


@pytest_asyncio.fixture(autouse=True)
async def fixture_sources(sessionmaker: Sessions) -> None:
    async with sessionmaker.begin() as session:
        for code in ("fixture", "fixture_b"):
            await ensure_dev_source(session, code)


async def _run_count(engine: AsyncEngine, status: str | None = None) -> int:
    found = await rows(
        engine,
        "SELECT count(*) FROM catalog.import_runs WHERE (CAST(:s AS text) IS NULL OR status = :s)",
        s=status,
    )
    return int(found[0][0])


async def test_first_run_loads_the_snapshot_and_records_provenance(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    result = await run_import(sessionmaker, FixtureImporter(), V1)

    assert result.counts["substances"]["inserted"] == 2
    assert result.counts["compositions"]["inserted"] == 2
    assert result.counts["products"]["inserted"] == 3
    assert result.counts["packages"]["inserted"] == 3
    assert result.counts["gtins"]["inserted"] == 3
    # One restricted (prefix 020) and one with a wrong check digit never reach the table.
    assert result.counts["gtins_skipped"] == RESTRICTED_AND_BAD_CHECK_DIGIT
    run = (await rows(engine, "SELECT * FROM catalog.import_runs"))[0]._mapping
    assert run["status"] == "succeeded"
    assert run["source"] == "fixture"
    assert run["source_version"] == "2026-01"
    assert len(run["snapshot_sha256"]) == 64
    assert run["finished_at"] >= run["started_at"]
    assert run["counts"]["products"]["inserted"] == 3
    assert run["error_code"] is None


async def test_ids_are_deterministic_and_compositions_carry_their_identity(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    await run_import(sessionmaker, FixtureImporter(), V1)

    product = await rows(engine, "SELECT id FROM catalog.products WHERE source_key = 'P-TEST-500'")
    assert product[0][0] == entity_id("fixture", "product", "P-TEST-500")
    substance = entity_id("fixture", "substance", "S-TEST")
    composition = await rows(
        engine,
        "SELECT id, identity_key, complete FROM catalog.compositions "
        "WHERE source_key = 'C-TEST-500'",
    )
    expected_key = composition_identity_key("TAB", [IngredientKey(substance, Decimal("500"), "mg")])
    assert composition[0][0] == entity_id("fixture", "composition", "C-TEST-500")
    assert composition[0][1] == expected_key
    assert composition[0][2] is True
    ingredients = await rows(
        engine,
        "SELECT strength_value, strength_unit FROM catalog.composition_ingredients "
        "WHERE composition_id = :c",
        c=composition[0][0],
    )
    assert [(str(v), u) for v, u in ingredients] == [("500", "mg")]


async def test_gtins_belong_to_their_source_and_package(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    await run_import(sessionmaker, FixtureImporter(), V1)

    found = await rows(
        engine,
        "SELECT g.gtin, g.source, g.origin, k.source_key FROM catalog.gtins g "
        "JOIN catalog.packages k ON k.id = g.package_id ORDER BY g.gtin",
    )
    assert [tuple(r) for r in found] == [
        ("04607012345677", "fixture", "source", "P-TEST-500-20"),
        ("05901234123457", "fixture", "source", "P-TEST-500-50"),
        ("14607012345674", "fixture", "source", "P-TEST-RU-10"),
    ]


async def test_running_twice_on_the_same_snapshot_changes_nothing(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    first = await run_import(sessionmaker, FixtureImporter(), V1)
    before = await dump(engine)

    second = await run_import(sessionmaker, FixtureImporter(), V1)

    assert await dump(engine) == before
    for table in ("substances", "compositions", "products", "packages", "gtins"):
        counts = second.counts[table]
        assert counts["inserted"] == counts["updated"] == counts["withdrawn"] == 0
        assert counts["unchanged"] == first.counts[table]["inserted"]
    assert await _run_count(engine, "succeeded") == 2
    # Rows still point at the run that last changed them.
    last = await rows(engine, "SELECT DISTINCT last_run_id FROM catalog.products")
    assert [r[0] for r in last] == [first.run_id]


async def test_a_record_missing_in_the_next_snapshot_is_withdrawn_but_stays_resolvable(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    first = await run_import(sessionmaker, FixtureImporter(), V1)
    second = await run_import(sessionmaker, FixtureImporter(), V2)

    assert second.counts["products"]["withdrawn"] == 1
    combo = entity_id("fixture", "product", "P-COMBO")
    found = await rows(
        engine,
        "SELECT brand_name, withdrawn_at IS NOT NULL, last_run_id FROM catalog.products "
        "WHERE id = :i",
        i=combo,
    )
    assert tuple(found[0]) == ("Fixtocombo", True, second.run_id)
    # A changed record is updated; an untouched one keeps its run.
    changed = await rows(
        engine,
        "SELECT manufacturer, last_run_id FROM catalog.products WHERE source_key = 'P-TEST-500'",
    )
    assert tuple(changed[0]) == ("Example Pharma Ltd", second.run_id)
    kept = await rows(
        engine,
        "SELECT last_run_id, withdrawn_at FROM catalog.products WHERE source_key = 'P-TEST-RU'",
    )
    assert tuple(kept[0]) == (first.run_id, None)
    assert second.counts["products"]["updated"] == 1
    assert second.counts["products"]["unchanged"] == 1


async def test_withdraw_missing_false_keeps_absent_rows_active(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    await run_import(sessionmaker, FixtureImporter(), V1)
    result = await run_import(sessionmaker, FixtureImporter(), V2, withdraw_missing=False)

    assert result.counts["products"]["withdrawn"] == 0
    found = await rows(engine, "SELECT count(*) FROM catalog.products WHERE withdrawn_at IS NULL")
    assert found[0][0] == 3


async def test_a_withdrawn_record_that_returns_is_active_again(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    await run_import(sessionmaker, FixtureImporter(), V1)
    await run_import(sessionmaker, FixtureImporter(), V2)
    third = await run_import(sessionmaker, FixtureImporter(), V1)

    found = await rows(
        engine,
        "SELECT withdrawn_at, last_run_id FROM catalog.products WHERE source_key = 'P-COMBO'",
    )
    assert tuple(found[0]) == (None, third.run_id)


async def test_the_same_composition_in_two_sources_is_two_rows(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    await run_import(sessionmaker, FixtureImporter(), V1)
    await run_import(sessionmaker, FixtureImporter(source="fixture_b"), V1)

    found = await rows(
        engine,
        "SELECT source, id, identity_key FROM catalog.compositions "
        "WHERE source_key = 'C-TEST-500' ORDER BY source",
    )
    assert [r[0] for r in found] == ["fixture", "fixture_b"]
    assert found[0][1] != found[1][1]  # ids carry the source
    # Substances differ per source, so identity keys differ too: no cross-market merge.
    assert found[0][2] != found[1][2]
    products = await rows(engine, "SELECT count(*) FROM catalog.products")
    assert products[0][0] == 6


async def test_a_second_concurrent_run_of_one_source_is_refused(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    async with sessionmaker.begin() as session:
        await session.execute(
            text(
                "INSERT INTO catalog.import_runs (id, source, snapshot_sha256, status) "
                "VALUES (:i, 'fixture', :h, 'running')"
            ),
            {"i": uuid.uuid4(), "h": "e" * 64},
        )
    with pytest.raises(ImportInProgress) as caught:
        await run_import(sessionmaker, FixtureImporter(), V1)
    assert caught.value.code == "import_in_progress"
    # The refused run left no trace, and another source is not blocked.
    assert await _run_count(engine) == 1
    await run_import(sessionmaker, FixtureImporter(source="fixture_b"), V1)


def _rename_and_break_a_package(data: dict[str, Any]) -> None:
    data["substances"][0]["name_en"] = "Renamed"
    data["products"][0]["brand_name"] = "Testamol Renamed"
    # count 0 violates the packages CHECK, after substances and products were already written.
    data["products"][2]["packages"] = [
        {"key": "P-BAD", "description": "bad", "count": "0", "count_unit": "tablet", "gtins": []}
    ]


async def test_a_failed_run_leaves_the_previous_state_and_is_recorded(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await run_import(sessionmaker, FixtureImporter(), V1)
    before = await dump(engine)
    broken = mutated_snapshot(tmp_path, _rename_and_break_a_package)

    with pytest.raises(ImporterError) as caught:
        await run_import(sessionmaker, FixtureImporter(), broken)

    assert caught.value.code == "import_failed"
    assert await dump(engine) == before  # entries, rows and names alike
    failed = await rows(
        engine,
        "SELECT status, error_code, finished_at IS NOT NULL FROM catalog.import_runs "
        "WHERE status = 'failed'",
    )
    assert [tuple(r) for r in failed] == [("failed", "import_failed", True)]
    # The failed run no longer blocks the next one.
    await run_import(sessionmaker, FixtureImporter(), V1)


def _drop_a_strength(data: dict[str, Any]) -> None:
    ingredient = data["compositions"][0]["ingredients"][0]
    del ingredient["strength_value"], ingredient["strength_unit"]


def _drop_the_form(data: dict[str, Any]) -> None:
    data["compositions"][0]["form_code"] = None


@pytest.mark.parametrize("mutate", [_drop_a_strength, _drop_the_form])
async def test_a_complete_composition_must_be_fully_specified(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path, mutate: Any
) -> None:
    snapshot = mutated_snapshot(tmp_path, mutate)

    with pytest.raises(ImporterDataError) as caught:
        await run_import(sessionmaker, FixtureImporter(), snapshot)

    assert caught.value.code == "incomplete_composition"
    assert await dump(engine) == {table: [] for table in DATA_TABLES}
    assert await _run_count(engine, "failed") == 1


async def test_a_product_with_an_unknown_composition_is_loaded_without_the_link(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    def unlink(data: dict[str, Any]) -> None:
        data["products"][0]["composition"] = "C-NOT-THERE"

    result = await run_import(sessionmaker, FixtureImporter(), mutated_snapshot(tmp_path, unlink))

    found = await rows(
        engine, "SELECT composition_id FROM catalog.products WHERE source_key = 'P-TEST-500'"
    )
    assert found[0][0] is None
    assert result.counts["products_unlinked"] == 1


async def test_search_entries_cover_products_and_substance_names(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    await run_import(sessionmaker, FixtureImporter(), V1)

    found = await rows(
        engine,
        "SELECT entity_kind, lang, text, norm FROM catalog.search_entries "
        "ORDER BY entity_kind, lang, text",
    )
    assert [tuple(r) for r in found] == [
        ("product", "en", "Fixtocombo", "fixtocombo"),
        ("product", "en", "Testamol 500", "testamol 500"),
        ("product", "ru", "Тестамол 500", "тестамол 500"),
        ("substance", "en", "Fixtocillin", "fixtocillin"),
        ("substance", "en", "Testamol", "testamol"),
        ("substance", "ru", "Тестамол", "тестамол"),
        ("substance", "ru", "Тестамолум", "тестамолум"),
        ("substance", "ru", "Фикстоциллин", "фикстоциллин"),
    ]


async def test_only_changed_entities_get_their_search_entries_rebuilt(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await run_import(sessionmaker, FixtureImporter(), V1)

    def rename(data: dict[str, Any]) -> None:
        data["products"][0]["brand_name"] = "Testamol Forte"
        data["substances"][1]["names"] = [{"lang": "en", "name": "Fixtocillinum"}]

    await run_import(sessionmaker, FixtureImporter(), mutated_snapshot(tmp_path, rename))

    texts = {r[0] for r in await rows(engine, "SELECT text FROM catalog.search_entries")}
    assert "Testamol Forte" in texts
    assert "Testamol 500" not in texts  # no stale entry of the old name
    assert "Fixtocillinum" in texts
    assert "Тестамол 500" in texts  # an untouched product keeps its entry
    names = {r[0] for r in await rows(engine, "SELECT name FROM catalog.substance_names")}
    assert "Fixtocillinum" in names


async def test_a_withdrawn_product_keeps_its_search_entry(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    await run_import(sessionmaker, FixtureImporter(), V1)
    await run_import(sessionmaker, FixtureImporter(), V2)

    texts = {r[0] for r in await rows(engine, "SELECT text FROM catalog.search_entries")}
    assert "Fixtocombo" in texts  # the API filters on withdrawn_at; the row stays resolvable


async def test_every_data_table_is_covered_by_the_failure_atomicity_check() -> None:
    assert "search_entries" in DATA_TABLES
    assert "import_runs" not in DATA_TABLES
