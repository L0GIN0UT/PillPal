"""openFDA NDC importer: pure parsing of a synthetic, format-faithful ``drug-ndc`` file, and the
load through the shared loader into real PostgreSQL."""

from __future__ import annotations

import json
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
from catalog.importers.openfda_ndc import OpenFdaNdcImporter
from tests.helpers import CATALOG_DIR
from tests.importers.support import rows

Sessions = async_sessionmaker[AsyncSession]
SNAPSHOT = CATALOG_DIR / "tests" / "fixtures" / "openfda"
DATA_FILE = "drug-ndc-0001-of-0001.json"
SNAPSHOT_DUP = CATALOG_DIR / "tests" / "fixtures" / "openfda_dup_package"


def _records(
    importer: OpenFdaNdcImporter | None = None,
) -> tuple[list[SubstanceRecord], list[CompositionRecord], list[ProductRecord]]:
    found = list((importer or OpenFdaNdcImporter()).parse(SNAPSHOT))
    return (
        [r for r in found if isinstance(r, SubstanceRecord)],
        [r for r in found if isinstance(r, CompositionRecord)],
        [r for r in found if isinstance(r, ProductRecord)],
    )


def _product(key: str) -> ProductRecord:
    return next(p for p in _records()[2] if p.source_key == key)


def test_the_source_and_license_match_the_seeded_row() -> None:
    importer = OpenFdaNdcImporter()

    assert importer.source == "openfda_ndc"
    assert importer.license.attribution == "Product data: openFDA (U.S. FDA)"
    importer.ensure_enabled()


def test_the_version_is_the_last_updated_date_of_the_file() -> None:
    assert OpenFdaNdcImporter().snapshot_version(SNAPSHOT) == "2026-10-30"


def test_records_come_as_substances_then_compositions_then_products() -> None:
    order = [type(r).__name__ for r in OpenFdaNdcImporter().parse(SNAPSHOT)]

    assert order == sorted(
        order, key=["SubstanceRecord", "CompositionRecord", "ProductRecord"].index
    )


def test_substances_are_source_local_by_normalized_name_and_listed_once() -> None:
    substances, _, _ = _records()

    assert {(s.source_key, s.name_en, s.market) for s in substances} == {
        ("name:testamolum", "Testamolum", "us"),
        ("name:fixtocillin sodium", "Fixtocillin sodium", "us"),
    }


def test_non_finished_non_human_and_malformed_products_are_skipped_and_counted() -> None:
    importer = OpenFdaNdcImporter()
    _, _, products = _records(importer)

    assert [p.source_key for p in products] == [
        "99999-111",
        "9999-1112",
        "55555-333",
        "11111-222",
        "22222-444",
    ]
    assert importer.skipped == {
        "not_finished": 1,
        "unsupported_product_type": 1,
        "invalid_product": 1,
        "duplicate_product": 1,
        "sample_package": 1,
    }


def test_a_product_with_rxcui_prefers_rxnorm_and_falls_back_to_its_local_composition() -> None:
    _, compositions, _ = _records()
    product = _product("99999-111")
    local = _product("9999-1112").composition_key

    assert product.composition_source == "rxnorm"
    assert product.composition_key == "900001"  # rxcuis in numeric order, not file order
    assert product.composition_alternatives == (("rxnorm", "900002"), ("openfda_ndc", local))
    assert any(c.source_key == local for c in compositions)  # same strings: one shared row
    assert product.brand_name == "Testamol 500"
    assert product.manufacturer == "Testlabs Inc."
    assert product.market == "us"
    assert product.rx_status == "rx"


def test_a_product_without_rxcui_gets_a_source_local_composition() -> None:
    _, compositions, _ = _records()
    product = _product("9999-1112")

    assert product.composition_source == "openfda_ndc"
    assert product.rx_status == "otc"
    assert product.brand_name == "Testamolum"  # no brand: the generic name
    local = next(c for c in compositions if c.source_key == product.composition_key)
    assert local.form_code == "tablet, film coated"
    assert local.form_name_en == "Tablet, film coated"
    assert local.complete is True
    [ingredient] = local.ingredients
    assert (ingredient.substance_key, ingredient.strength_value, ingredient.strength_unit) == (
        "name:testamolum",
        Decimal(500),
        "mg",
    )
    assert (ingredient.per_value, ingredient.per_unit) == (None, None)


def test_multi_ingredient_and_per_volume_strengths_are_parsed() -> None:
    _, compositions, _ = _records()
    by_key = {c.source_key: c for c in compositions}

    combo = by_key[_product("55555-333").composition_key or ""]
    assert {(i.substance_key, i.strength_value, i.strength_unit) for i in combo.ingredients} == {
        ("name:testamolum", Decimal(250), "mg"),
        ("name:fixtocillin sodium", Decimal(30), "mg"),
    }
    assert combo.complete is True
    solution = by_key[_product("11111-222").composition_key or ""]
    [ingredient] = solution.ingredients
    assert (ingredient.strength_value, ingredient.per_value, ingredient.per_unit) == (
        Decimal(250),
        Decimal(5),
        "mL",
    )


def test_an_unparseable_strength_makes_an_incomplete_composition() -> None:
    _, compositions, _ = _records()
    weird = next(c for c in compositions if c.source_key == _product("22222-444").composition_key)

    assert weird.complete is False
    assert weird.ingredients[0].strength_value is None


def test_equal_compositions_share_one_local_key_and_it_is_stable() -> None:
    _, first, _ = _records()
    _, second, _ = _records()

    assert [c.source_key for c in first] == [c.source_key for c in second]
    assert len({c.source_key for c in first}) == len(first) == 4
    assert all(c.source_key.startswith("local:v1:") for c in first)


def test_packages_carry_count_and_gtin_and_unparseable_counts_are_null() -> None:
    packages = {pkg.source_key: pkg for p in _records()[2] for pkg in p.packages}

    bottle = packages["99999-111-22"]
    assert (bottle.count, bottle.count_unit) == (Decimal(100), "tablet, film coated")
    assert bottle.gtins == ("00399999111225",)
    blister = packages["99999-111-30"]
    assert blister.count == Decimal(20)
    assert "99999-111-99" not in packages  # a sample is not a package for sale
    assert packages["99999-111-30"].gtins == ("00399999111300",)
    assert packages["9999-1112-30"].gtins == ("00399991112305",)
    kit = packages["55555-333-01"]
    assert (kit.count, kit.count_unit) == (None, None)
    assert kit.gtins == ("00355555333012",)
    # An NDC that is not a package NDC in a printed configuration has no GTIN.
    assert packages["55555-333"].gtins == ()
    assert packages["11111-222-1"].gtins == ()
    assert packages["11111-222-1"].count == Decimal(473)


def test_a_file_that_is_not_json_is_a_data_error(tmp_path: Path) -> None:
    dest = tmp_path / "snap"
    dest.mkdir()
    (dest / DATA_FILE).write_text("{not json", encoding="utf-8")

    with pytest.raises(ImporterDataError):
        list(OpenFdaNdcImporter().parse(dest))


def test_an_empty_snapshot_directory_is_refused(tmp_path: Path) -> None:
    with pytest.raises(ImporterError) as caught:
        list(OpenFdaNdcImporter().parse(tmp_path))

    assert caught.value.code == "snapshot_not_found"


def test_hostile_field_types_skip_the_product_instead_of_crashing(tmp_path: Path) -> None:
    dest = tmp_path / "snap"
    dest.mkdir()
    (dest / DATA_FILE).write_text(
        '{"meta": {}, "results": ['
        '{"product_ndc": 5, "finished": true},'
        '"just a string",'
        '{"product_ndc": "1-2", "finished": true, "product_type": "HUMAN OTC DRUG",'
        ' "brand_name": ["x"], "active_ingredients": "none", "packaging": {"a": 1}},'
        '{"product_ndc": "12345-678", "finished": true, "product_type": "HUMAN OTC DRUG",'
        ' "brand_name": "Okname", "active_ingredients": [1, {"name": 7}, {"name": "A"}],'
        ' "packaging": [3, {"package_ndc": 9}],'
        ' "openfda": {"rxcui": ["12", "x", 5, "1234567890123"]}}'
        "]}",
        encoding="utf-8",
    )
    importer = OpenFdaNdcImporter()

    found = list(importer.parse(dest))

    products = [r for r in found if isinstance(r, ProductRecord)]
    assert [p.source_key for p in products] == ["12345-678"]
    assert products[0].composition_key == "12"
    assert [a[0] for a in products[0].composition_alternatives] == ["openfda_ndc"]
    assert products[0].packages == ()
    assert importer.skipped["invalid_product"] >= 3


async def test_load_inserts_products_packages_gtins_and_links_to_local_compositions(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    result = await run_import(sessionmaker, OpenFdaNdcImporter(), SNAPSHOT)

    counts = result.counts
    assert counts["substances"]["inserted"] == 2
    assert counts["compositions"]["inserted"] == 4
    assert counts["products"]["inserted"] == 5
    assert counts["packages"]["inserted"] == 7  # three on the first product, minus the sample
    assert counts["gtins"]["inserted"] == 5
    assert counts["products_unlinked"] == 0  # the rxcui product falls back to its local row
    assert counts["parse_skipped"]["not_finished"] == 1
    run = (
        await rows(
            engine,
            "SELECT source_version, status FROM catalog.import_runs WHERE source <> 'consensus'",
        )
    )[0]
    assert tuple(run) == ("2026-10-30", "succeeded")
    linked = await rows(
        engine,
        "SELECT p.source_key, c.source FROM catalog.products p "
        "LEFT JOIN catalog.compositions c ON c.id = p.composition_id ORDER BY p.source_key",
    )
    assert {r[1] for r in linked} == {"openfda_ndc"}


async def test_a_second_run_on_the_same_snapshot_changes_nothing(
    sessionmaker: Sessions,
) -> None:
    await run_import(sessionmaker, OpenFdaNdcImporter(), SNAPSHOT)

    second = await run_import(sessionmaker, OpenFdaNdcImporter(), SNAPSHOT)

    for table in ("substances", "compositions", "products", "packages", "gtins"):
        counts = second.counts[table]
        assert counts["inserted"] == counts["updated"] == counts["withdrawn"] == 0


async def test_a_product_missing_from_the_next_snapshot_is_withdrawn_not_deleted(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await run_import(sessionmaker, OpenFdaNdcImporter(), SNAPSHOT)
    text = (SNAPSHOT / DATA_FILE).read_text(encoding="utf-8")
    smaller = tmp_path / "v2"
    smaller.mkdir()
    (smaller / DATA_FILE).write_text(
        text.replace('"product_ndc": "11111-222"', '"product_ndc": "11111-9999"'), encoding="utf-8"
    )

    result = await run_import(sessionmaker, OpenFdaNdcImporter(), smaller)

    assert result.counts["products"]["withdrawn"] == 1
    gone = await rows(
        engine,
        "SELECT withdrawn_at IS NOT NULL FROM catalog.products WHERE source_key = '11111-222'",
    )
    assert gone[0][0] is True


def test_a_second_data_file_in_the_snapshot_is_read_after_the_first(tmp_path: Path) -> None:
    dest = tmp_path / "snap"
    dest.mkdir()
    shutil.copy(SNAPSHOT / DATA_FILE, dest / "drug-ndc-0001-of-0002.json")
    (dest / "drug-ndc-0002-of-0002.json").write_text(
        '{"meta": {"last_updated": "2026-10-30"}, "results": ['
        '{"product_ndc": "77777-888", "finished": true, "product_type": "HUMAN OTC DRUG",'
        ' "brand_name": "Secondfile", "dosage_form": "TABLET",'
        ' "active_ingredients": [{"name": "TESTAMOLUM", "strength": "5 mg/1"}]}]}',
        encoding="utf-8",
    )

    products = [r for r in OpenFdaNdcImporter().parse(dest) if isinstance(r, ProductRecord)]

    assert [p.source_key for p in products][-1] == "77777-888"
    assert len(products) == 6


def test_nul_and_lone_surrogates_in_a_name_skip_the_product(tmp_path: Path) -> None:
    dest = tmp_path / "snap"
    dest.mkdir()
    base = {"finished": True, "product_type": "HUMAN OTC DRUG"}
    results = [
        {**base, "product_ndc": "12345-678", "brand_name": "Nul" + chr(0) + "name"},
        {**base, "product_ndc": "12345-679", "brand_name": "Lone" + chr(0xD800) + "surrogate"},
    ]
    (dest / DATA_FILE).write_text(json.dumps({"meta": {}, "results": results}), encoding="utf-8")
    importer = OpenFdaNdcImporter()

    assert [r for r in importer.parse(dest) if isinstance(r, ProductRecord)] == []
    assert importer.skipped["invalid_product"] == 2


def test_a_package_ndc_listed_under_two_products_is_kept_once() -> None:
    importer = OpenFdaNdcImporter()
    products = [r for r in importer.parse(SNAPSHOT_DUP) if isinstance(r, ProductRecord)]

    owners = [p.source_key for p in products for k in p.packages if k.source_key == "99999-111-22"]
    assert owners == ["99999-111"]
    assert importer.skipped["duplicate_package"] == 1


def test_the_form_name_is_capitalized_once() -> None:
    _, compositions, _ = _records()

    assert {c.form_name_en for c in compositions} >= {"Tablet, film coated", "Solution"}
