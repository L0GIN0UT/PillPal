"""RxNorm Prescribable importer: pure parsing of synthetic RRF files (format of ``RXNCONSO``,
``RXNREL``, ``RXNSAT``, ``RXNSAB``) and the load through the shared loader."""

from __future__ import annotations

import shutil
from decimal import Decimal
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
from catalog.importers.loader import run_import
from catalog.importers.rxnorm import RxNormImporter
from tests.helpers import CATALOG_DIR
from tests.importers.support import rows

Sessions = async_sessionmaker[AsyncSession]
SNAPSHOT = CATALOG_DIR / "tests" / "fixtures" / "rxnorm"
RRF = SNAPSHOT / "rrf"


def _parse(
    importer: RxNormImporter | None = None, snapshot: Path = SNAPSHOT
) -> tuple[list[SubstanceRecord], dict[str, CompositionRecord]]:
    found = list((importer or RxNormImporter()).parse(snapshot))
    assert not any(isinstance(r, ProductRecord) for r in found)  # no products from RxNorm
    return (
        [r for r in found if isinstance(r, SubstanceRecord)],
        {r.source_key: r for r in found if isinstance(r, CompositionRecord)},
    )


def _copy_files(tmp_path: Path, into_rrf_dir: bool) -> Path:
    dest = tmp_path / "snap"
    target = dest / "rrf" if into_rrf_dir else dest
    target.mkdir(parents=True)
    for path in RRF.glob("*.RRF"):
        shutil.copy(path, target / path.name)
    return dest


def test_source_and_license_match_the_seeded_row() -> None:
    importer = RxNormImporter()

    assert importer.source == "rxnorm"
    assert (
        importer.license.attribution
        == "Substance and composition data: RxNorm, U.S. National Library of Medicine"
    )
    importer.ensure_enabled()


def test_the_version_comes_from_rxnsab() -> None:
    assert RxNormImporter().snapshot_version(SNAPSHOT) == "20261102"


def test_the_version_is_none_without_rxnsab(tmp_path: Path) -> None:
    snapshot = _copy_files(tmp_path, into_rrf_dir=True)
    (snapshot / "rrf" / "RXNSAB.RRF").unlink()

    assert RxNormImporter().snapshot_version(snapshot) is None


def test_files_directly_in_the_snapshot_directory_are_found_too(tmp_path: Path) -> None:
    snapshot = _copy_files(tmp_path, into_rrf_dir=False)

    assert len(_parse(snapshot=snapshot)[1]) == 6


def test_substances_are_the_ingredients_and_precise_ingredients_of_rxnorm() -> None:
    substances, _ = _parse()

    assert [(s.source_key, s.name_en, s.market) for s in substances] == [
        ("900101", "testamolum", "us"),
        ("900102", "testamolum hydrochloride", "us"),
        ("900103", "fixtocillin", "us"),
    ]  # suppressed, foreign-vocabulary and non-English atoms are not in


def test_records_come_substances_first() -> None:
    kinds = [type(r) for r in RxNormImporter().parse(SNAPSHOT)]

    assert kinds == sorted(kinds, key=[SubstanceRecord, CompositionRecord].index)


def test_a_single_ingredient_scd_has_its_strength_and_form() -> None:
    _, compositions = _parse()
    scd = compositions["900001"]

    assert (scd.market, scd.form_code, scd.form_name_en, scd.complete) == (
        "us",
        "900301",
        "Oral Tablet",
        True,
    )
    [ingredient] = scd.ingredients
    assert (ingredient.substance_key, ingredient.strength_value, ingredient.strength_unit) == (
        "900101",
        Decimal(500),
        "mg",
    )
    assert (ingredient.per_value, ingredient.per_unit) == (None, None)


def test_a_multi_ingredient_scd_links_each_component_to_its_ingredient() -> None:
    _, compositions = _parse()

    combo = {
        (i.substance_key, i.strength_value, i.strength_unit)
        for i in compositions["900003"].ingredients
    }

    assert combo == {("900101", Decimal(250), "mg"), ("900103", Decimal(30), "mg")}


def test_a_per_volume_strength_keeps_its_denominator() -> None:
    _, compositions = _parse()
    [ingredient] = compositions["900004"].ingredients

    assert (ingredient.strength_value, ingredient.per_value, ingredient.per_unit) == (
        Decimal(50),
        Decimal(1),
        "mL",
    )
    assert compositions["900004"].form_name_en == "Oral Solution"


def test_the_ingredient_wins_over_the_precise_ingredient() -> None:
    _, compositions = _parse()

    assert [i.substance_key for i in compositions["900010"].ingredients] == ["900101"]


def test_available_strength_is_the_fallback_for_a_single_ingredient_scd() -> None:
    _, compositions = _parse()
    [ingredient] = compositions["900011"].ingredients

    assert (ingredient.strength_value, ingredient.strength_unit) == (Decimal(20), "MG")
    assert compositions["900011"].complete is True


def test_a_scd_without_a_dose_form_is_incomplete() -> None:
    _, compositions = _parse()

    assert compositions["900007"].form_code is None
    assert compositions["900007"].complete is False


def test_unusable_scds_are_skipped_and_counted_never_guessed() -> None:
    importer = RxNormImporter()
    _, compositions = _parse(importer)

    assert sorted(compositions) == ["900001", "900003", "900004", "900007", "900010", "900011"]
    assert importer.skipped == {
        "no_ingredients": 1,  # 900005
        "unknown_ingredient": 1,  # 900006: its ingredient is not in the file
        "duplicate_composition": 1,  # 900008 equals 900001; the lowest rxcui wins
    }


def test_a_missing_core_file_is_refused(tmp_path: Path) -> None:
    snapshot = _copy_files(tmp_path, into_rrf_dir=True)
    (snapshot / "rrf" / "RXNREL.RRF").unlink()

    with pytest.raises(ImporterError) as caught:
        list(RxNormImporter().parse(snapshot))

    assert caught.value.code == "snapshot_not_found"


def test_an_overlong_line_is_a_data_error_not_a_memory_problem(tmp_path: Path) -> None:
    snapshot = _copy_files(tmp_path, into_rrf_dir=True)
    with (snapshot / "rrf" / "RXNSAT.RRF").open("a", encoding="utf-8") as handle:
        handle.write("x" * 200_000 + "\n")

    with pytest.raises(ImporterDataError):
        list(RxNormImporter().parse(snapshot))


def test_invalid_utf8_is_a_data_error(tmp_path: Path) -> None:
    snapshot = _copy_files(tmp_path, into_rrf_dir=True)
    with (snapshot / "rrf" / "RXNCONSO.RRF").open("ab") as handle:
        handle.write(b"900999|ENG|\xff\xfe|\n")

    with pytest.raises(ImporterDataError):
        list(RxNormImporter().parse(snapshot))


def test_a_non_numeric_strength_leaves_the_strength_empty(tmp_path: Path) -> None:
    snapshot = _copy_files(tmp_path, into_rrf_dir=True)
    sat = snapshot / "rrf" / "RXNSAT.RRF"
    sat.write_text(
        sat.read_text(encoding="utf-8").replace("|250|N||", "|lots|N||"), encoding="utf-8"
    )

    _, compositions = _parse(snapshot=snapshot)

    combo = {i.substance_key: i.strength_value for i in compositions["900003"].ingredients}
    assert combo == {"900101": None, "900103": Decimal(30)}
    assert compositions["900003"].complete is False


async def test_load_inserts_substances_and_compositions_with_strengths(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    result = await run_import(sessionmaker, RxNormImporter(), SNAPSHOT)

    counts = result.counts
    assert counts["substances"]["inserted"] == 3
    assert counts["compositions"]["inserted"] == 6
    assert counts["parse_skipped"]["duplicate_composition"] == 1
    assert counts["products"]["inserted"] == 0  # RxNorm carries no products
    found = await rows(
        engine,
        "SELECT s.source_key, ci.strength_value, ci.strength_unit, ci.per_value, ci.per_unit "
        "FROM catalog.compositions c JOIN catalog.composition_ingredients ci "
        "ON ci.composition_id = c.id JOIN catalog.substances s ON s.id = ci.substance_id "
        "WHERE c.source_key = '900004'",
    )
    assert [(r[0], str(r[1]), r[2], str(r[3]), r[4]) for r in found] == [
        ("900103", "50", "mg", "1", "mL")
    ]
    run = (await rows(engine, "SELECT source_version, status FROM catalog.import_runs"))[0]
    assert tuple(run) == ("20261102", "succeeded")


async def test_a_second_run_changes_nothing(sessionmaker: Sessions) -> None:
    await run_import(sessionmaker, RxNormImporter(), SNAPSHOT)

    second = await run_import(sessionmaker, RxNormImporter(), SNAPSHOT)

    for table in ("substances", "compositions"):
        counts = second.counts[table]
        assert counts["inserted"] == counts["updated"] == counts["withdrawn"] == 0
