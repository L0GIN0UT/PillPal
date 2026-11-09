"""EMA centrally authorised medicines: parsing (pure) and loading (real PostgreSQL)."""

from __future__ import annotations

from pathlib import Path

import pytest
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from catalog.importers.base import (
    CompositionRecord,
    ImporterDataError,
    ImporterError,
    ProductRecord,
    SubstanceRecord,
)
from catalog.importers.ema import EmaImporter
from catalog.importers.loader import run_import
from tests.importers import ema_data
from tests.importers.ema_data import HOLDER, NUMBER, row
from tests.importers.support import rows
from tests.importers.xlsx_support import build_xlsx

Sessions = async_sessionmaker[AsyncSession]


def _parse(folder: Path, max_rows: int | None = None) -> tuple[EmaImporter, list[object]]:
    importer = EmaImporter() if max_rows is None else EmaImporter(max_rows=max_rows)
    return importer, list(importer.parse(folder))


def _products(records: list[object]) -> dict[str, ProductRecord]:
    return {r.source_key: r for r in records if isinstance(r, ProductRecord)}


def _compositions(records: list[object]) -> list[CompositionRecord]:
    return [r for r in records if isinstance(r, CompositionRecord)]


def _composition_of(records: list[object], number: str) -> CompositionRecord:
    key = _products(records)[number].composition_key
    return next(c for c in _compositions(records) if c.source_key == key)


def test_a_product_with_several_substances_gets_an_incomplete_composition(tmp_path: Path) -> None:
    _, records = _parse(ema_data.snapshot(tmp_path / "s"))

    composition = _composition_of(records, "EMEA/H/C/900002")
    assert [i.substance_key for i in composition.ingredients] == ["name:probinol", "name:testamol"]
    assert composition.complete is False
    assert composition.form_code is None
    assert all(i.strength_value is None for i in composition.ingredients)


def test_no_composition_is_ever_complete(tmp_path: Path) -> None:
    _, records = _parse(ema_data.snapshot(tmp_path / "s"))
    assert _compositions(records)
    assert not any(c.complete for c in _compositions(records))


def test_separators_of_substance_lists_are_understood(tmp_path: Path) -> None:
    _, records = _parse(ema_data.snapshot(tmp_path / "s"))
    assert len(_composition_of(records, "EMEA/H/C/900007").ingredients) == 3


def test_the_marketing_authorisation_holder_is_the_manufacturer(tmp_path: Path) -> None:
    _, records = _parse(ema_data.snapshot(tmp_path / "s"))

    products = _products(records)
    assert products["EMEA/H/C/900001"].manufacturer == HOLDER
    assert products["EMEA/H/C/900002"].manufacturer == "Probin Holdings GmbH"
    first = products["EMEA/H/C/900001"]
    assert (first.market, first.brand_name, first.country) == ("eu", "Testamolex", None)
    assert first.packages == ()  # EMA prints no GTIN and no pack


def test_the_same_substances_share_one_composition_and_substance(tmp_path: Path) -> None:
    _, records = _parse(ema_data.snapshot(tmp_path / "s"))

    products = _products(records)
    assert (
        products["EMEA/H/C/900001"].composition_key == products["EMEA/H/C/900003"].composition_key
    )
    substances = [r.source_key for r in records if isinstance(r, SubstanceRecord)]
    assert substances == sorted(set(substances))
    assert "name:testamol" in substances


def test_only_authorised_human_medicines_are_kept_and_the_rest_is_counted(tmp_path: Path) -> None:
    importer, records = _parse(ema_data.snapshot(tmp_path / "s"))

    assert set(_products(records)) == {
        "EMEA/H/C/900001",
        "EMEA/H/C/900002",
        "EMEA/H/C/900003",
        "EMEA/H/C/900007",
    }
    assert importer.skipped == {"not_authorised": 2, "not_human": 1}


def test_invalid_and_duplicate_rows_are_counted(tmp_path: Path) -> None:
    data = [
        row("Okex", "testamol", "EMEA/H/C/1"),
        row("Okex Again", "testamol", "EMEA/H/C/1"),
        row("", "testamol", "EMEA/H/C/2"),
        row("Nosubstance", "  ", "EMEA/H/C/3"),
        row("Nonumber", "testamol", ""),
    ]
    importer, records = _parse(ema_data.snapshot(tmp_path / "s", data))

    assert list(_products(records)) == ["EMEA/H/C/1"]
    assert importer.skipped == {"duplicate_product": 1, "invalid_product": 3}


def test_an_empty_status_or_category_cell_never_means_authorised_human(tmp_path: Path) -> None:
    data = [
        row("Okex", "testamol", "EMEA/H/C/1"),
        row("Nostatus", "testamol", "EMEA/H/C/2", status=""),
        row("Nocategory", "testamol", "EMEA/H/C/3", category=""),
    ]
    importer, records = _parse(ema_data.snapshot(tmp_path / "s", data))

    assert list(_products(records)) == ["EMEA/H/C/1"]
    assert importer.skipped == {"not_authorised": 1, "not_human": 1}


def test_a_file_without_a_status_column_is_refused(tmp_path: Path) -> None:
    folder = tmp_path / "s"
    folder.mkdir()
    header = [h for h in ema_data.HEADER if h != "Authorisation status"]
    build_xlsx(folder / "ema.xlsx", {"x": [header, ["Human", "Okex", "t", "testamol", "N1"]]})
    with pytest.raises(ImporterDataError) as caught:
        _parse(folder)
    assert caught.value.code == "missing_columns"


def test_a_substance_name_with_a_comma_is_split_at_it(tmp_path: Path) -> None:
    # Known limit (documented in ema.py): the list separator cannot be told from a comma in a
    # name. The effect is an extra substance, i.e. at worst a false overlap hint.
    data = [row("Dichlorex", "2,4-dichlorobenzyl alcohol", "EMEA/H/C/1")]
    _, records = _parse(ema_data.snapshot(tmp_path / "s", data))

    composition = _composition_of(records, "EMEA/H/C/1")
    assert [i.substance_key for i in composition.ingredients] == [
        "name:2",
        "name:4-dichlorobenzyl alcohol",
    ]


def test_a_workbook_without_the_columns_is_refused(tmp_path: Path) -> None:
    folder = tmp_path / "s"
    folder.mkdir()
    build_xlsx(folder / "ema.xlsx", {"x": [["a", "b"], ["1", "2"]]})
    with pytest.raises(ImporterDataError) as caught:
        _parse(folder)
    assert caught.value.code == "missing_columns"


def test_nothing_to_import_is_refused(tmp_path: Path) -> None:
    only_refused = [row("Refusedex", "ramolin", "EMEA/H/C/5", status="Refused")]
    with pytest.raises(ImporterDataError) as caught:
        _parse(ema_data.snapshot(tmp_path / "s", only_refused))
    assert caught.value.code == "empty_snapshot"


def test_a_snapshot_must_hold_exactly_one_workbook(tmp_path: Path) -> None:
    folder = ema_data.snapshot(tmp_path / "s")
    ema_data.workbook(folder / "second.xlsx")
    with pytest.raises(ImporterError) as caught:
        _parse(folder)
    assert caught.value.code == "snapshot_ambiguous"
    empty = tmp_path / "e"
    empty.mkdir()
    with pytest.raises(ImporterError) as caught:
        _parse(empty)
    assert caught.value.code == "snapshot_not_found"


def test_the_workbook_limits_apply(tmp_path: Path) -> None:
    with pytest.raises(ImporterDataError) as caught:
        _parse(ema_data.snapshot(tmp_path / "s"), max_rows=4)
    assert caught.value.code == "xlsx_too_large"


def test_the_version_is_the_modification_day(tmp_path: Path) -> None:
    folder = ema_data.snapshot(tmp_path / "s")
    assert EmaImporter().snapshot_version(folder) == "2026-10-01"


async def test_import_loads_eu_products_with_incomplete_compositions(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    result = await run_import(sessionmaker, EmaImporter(), ema_data.snapshot(tmp_path / "s"))

    assert result.counts["products"]["inserted"] == 4  # type: ignore[index]
    assert result.counts["parse_skipped"]["not_authorised"] == 2  # type: ignore[index]
    products = await rows(
        engine,
        "SELECT brand_name, market, manufacturer FROM catalog.products "
        "WHERE source = 'ema' ORDER BY source_key",
    )
    assert tuple(products[0]) == ("Testamolex", "eu", HOLDER)
    assert {p[1] for p in products} == {"eu"}
    complete = "SELECT count(*) FROM catalog.compositions WHERE source = 'ema' AND complete"
    assert (await rows(engine, complete))[0][0] == 0
    unlinked = (
        "SELECT count(*) FROM catalog.products WHERE source = 'ema' AND composition_id IS NULL"
    )
    assert (await rows(engine, unlinked))[0][0] == 0
    assert (await rows(engine, "SELECT count(*) FROM catalog.gtins"))[0][0] == 0
    flag = await rows(engine, "SELECT enabled FROM catalog.sources WHERE code = 'ema'")
    assert flag == [(True,)]
    version = await rows(
        engine, "SELECT source_version FROM catalog.import_runs WHERE source = 'ema'"
    )
    assert version == [("2026-10-01",)]


async def test_a_reimport_withdraws_what_the_file_no_longer_lists(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await run_import(sessionmaker, EmaImporter(), ema_data.snapshot(tmp_path / "a"))
    # The generic disappears from the file and the triple is now withdrawn from the market.
    changed = [
        row("Triplex", "alfanol", "EMEA/H/C/900007", status="Withdrawn")
        if r[NUMBER] == "EMEA/H/C/900007"
        else r
        for r in ema_data.ROWS
        if r[NUMBER] != "EMEA/H/C/900003"
    ]

    await run_import(sessionmaker, EmaImporter(), ema_data.snapshot(tmp_path / "b", changed))

    live = await rows(
        engine,
        "SELECT source_key FROM catalog.products WHERE source = 'ema' AND withdrawn_at IS NULL "
        "ORDER BY source_key",
    )
    assert [r[0] for r in live] == ["EMEA/H/C/900001", "EMEA/H/C/900002"]
    complete = "SELECT count(*) FROM catalog.compositions WHERE source = 'ema' AND complete"
    assert (await rows(engine, complete))[0][0] == 0
