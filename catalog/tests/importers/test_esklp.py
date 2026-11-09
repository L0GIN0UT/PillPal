"""The ESKLP importer: refusal while the flag is off, parsing of the XML and xlsx shapes into
the same records, the counted drops, and the guards on a snapshot that is incomplete."""

from __future__ import annotations

from pathlib import Path

import pytest

from catalog.config import Settings
from catalog.importers.base import (
    CompositionRecord,
    ImporterDataError,
    ImporterDisabled,
    ImporterError,
    ProductRecord,
    Record,
    SubstanceRecord,
)
from catalog.importers.esklp import EsklpImporter
from tests.conftest import TEST_DATABASE_URL, make_settings
from tests.importers import ru_data
from tests.importers.ru_data import ESKLP_DIR, uid
from tests.importers.xlsx_support import build_xlsx


def _importer() -> EsklpImporter:
    return EsklpImporter(enabled=True)


def _xml_snapshot(tmp_path: Path, name: str = "xml") -> Path:
    folder = tmp_path / name
    folder.mkdir()
    (folder / "esklp.xml").write_text(ru_data.esklp_xml(), encoding="utf-8")
    return folder


def _parse(folder: Path) -> tuple[list[Record], dict[str, int]]:
    importer = _importer()
    records = list(importer.parse(folder))
    return records, dict(importer.skipped)


def test_the_flags_default_to_off() -> None:
    settings = make_settings()
    assert settings.importer_esklp_enabled is False
    assert settings.importer_grls_enabled is False


def test_the_flags_come_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CATALOG_DATABASE_URL", TEST_DATABASE_URL)
    monkeypatch.setenv("CATALOG_IMPORTER_ESKLP_ENABLED", "true")
    monkeypatch.setenv("CATALOG_IMPORTER_GRLS_ENABLED", "true")
    settings = Settings()  # type: ignore[call-arg]
    assert settings.importer_esklp_enabled is True
    assert settings.importer_grls_enabled is True


def test_every_operation_refuses_while_the_flag_is_off(tmp_path: Path) -> None:
    importer = EsklpImporter(enabled=False)
    snapshot = _xml_snapshot(tmp_path)
    assert importer.source == "esklp"

    with pytest.raises(ImporterDisabled) as caught:
        importer.ensure_enabled()
    assert caught.value.code == "importer_disabled"
    with pytest.raises(ImporterDisabled):
        importer.fetch(tmp_path / "out")
    with pytest.raises(ImporterDisabled):
        importer.snapshot_version(snapshot)
    with pytest.raises(ImporterDisabled):
        list(importer.parse(snapshot))
    assert not (tmp_path / "out").exists()


def test_the_committed_fixture_is_the_generated_one() -> None:
    assert (ESKLP_DIR / "esklp.xml").read_text(encoding="utf-8") == ru_data.esklp_xml()


def test_xml_records_follow_the_load_order_and_the_catalog_contract(tmp_path: Path) -> None:
    records, skipped = _parse(_xml_snapshot(tmp_path))

    order = (SubstanceRecord, CompositionRecord, ProductRecord)
    levels = [order.index(type(r)) for r in records]  # type: ignore[arg-type]
    assert levels == sorted(levels)
    substances = {r.source_key: r for r in records if isinstance(r, SubstanceRecord)}
    names = {s.name_ru for s in substances.values()}
    assert names == {"Тестамол", "Пробинол", "Ёжикаин", "Рамолин"}
    assert all(s.market == "ru" and s.name_en is None for s in substances.values())
    assert "inn:ежикаин" in substances  # keys fold ё

    compositions = {r.source_key: r for r in records if isinstance(r, CompositionRecord)}
    assert set(compositions) == {uid(1), uid(2), uid(3), uid(5)}  # uid(4) repeats uid(1)
    assert compositions[uid(1)].complete is True
    assert compositions[uid(1)].form_name_ru == "таблетки"
    assert compositions[uid(2)].complete is True
    assert len(compositions[uid(2)].ingredients) == 2
    assert compositions[uid(3)].complete is False  # no dosage printed
    assert compositions[uid(5)].ingredients[0].per_value is not None  # 100 мг / 5 мл

    products = {r.source_key: r for r in records if isinstance(r, ProductRecord)}
    assert set(products) == {uid(n) for n in range(101, 107)}
    first = products[uid(101)]
    assert (first.brand_name, first.market, first.country) == ("Тестамол 500", "ru", "Россия")
    assert first.manufacturer == 'ООО "Тест-Фарм"'
    assert first.composition_key == uid(1)
    assert first.registration_number == "ЛП-000001"
    assert first.packages[0].gtins == ("04600000000015",)
    assert first.packages[0].description == "блистер, пачка"
    assert products[uid(104)].composition_key == uid(1)  # mapped to the kept composition
    assert products[uid(104)].registration_number == "ЛП-000001"  # printed as " лп-000001 "
    assert products[uid(106)].composition_key is None
    assert products[uid(103)].packages[0].gtins == ()  # an empty barcode is not an error
    assert set(products[uid(105)].packages[0].gtins) == {"04600000000022", "04600000000077"}

    assert skipped == {
        "invalid_klp": 1,
        "duplicate_klp": 1,
        "duplicate_composition": 1,
        "klp_without_smnn": 1,
        "gtin_invalid": 1,
        "gtin_restricted": 1,
    }


def test_the_manufacturer_is_the_published_name_and_never_the_address(tmp_path: Path) -> None:
    records, _ = _parse(_xml_snapshot(tmp_path))

    forte = next(r for r in records if isinstance(r, ProductRecord) and r.source_key == uid(102))
    assert forte.manufacturer == ru_data.IE_NAME
    assert ru_data.IE_ADDRESS not in repr(records)


@pytest.mark.parametrize("two_sheets", [False, True])
def test_the_xlsx_shapes_give_the_same_records_as_the_xml(tmp_path: Path, two_sheets: bool) -> None:
    folder = tmp_path / "book"
    folder.mkdir()
    ru_data.esklp_xlsx(folder / "esklp.xlsx", two_sheets=two_sheets)

    from_book, skipped = _parse(folder)

    from_xml, _ = _parse(_xml_snapshot(tmp_path))
    assert from_book == from_xml
    assert skipped["invalid_klp"] == 1
    assert ru_data.IE_ADDRESS not in repr(from_book)


def test_the_version_is_the_root_attribute_or_the_workbook_date(tmp_path: Path) -> None:
    assert _importer().snapshot_version(_xml_snapshot(tmp_path)) == "2026-10-01"
    folder = tmp_path / "book"
    folder.mkdir()
    ru_data.esklp_xlsx(folder / "esklp.xlsx")
    assert _importer().snapshot_version(folder) == "2026-10-01"


def test_a_snapshot_without_trade_items_is_refused(tmp_path: Path) -> None:
    folder = tmp_path / "empty"
    folder.mkdir()
    (folder / "esklp.xml").write_text('<?xml version="1.0"?><esklp version="1"></esklp>')

    with pytest.raises(ImporterDataError) as caught:
        _parse(folder)
    assert caught.value.code == "empty_snapshot"


def test_a_workbook_without_the_expected_columns_is_refused(tmp_path: Path) -> None:
    folder = tmp_path / "book"
    folder.mkdir()
    build_xlsx(folder / "esklp.xlsx", {"Лист1": [["Название", "Цена"], ["Тестамол", "10"]]})

    with pytest.raises(ImporterDataError) as caught:
        _parse(folder)
    assert caught.value.code == "missing_columns"


def test_a_truncated_xml_file_is_refused_before_anything_is_loaded(tmp_path: Path) -> None:
    folder = _xml_snapshot(tmp_path)
    text = (folder / "esklp.xml").read_text(encoding="utf-8")
    (folder / "esklp.xml").write_text(text[: len(text) // 2], encoding="utf-8")

    with pytest.raises(ImporterDataError) as caught:
        _parse(folder)
    assert caught.value.code == "invalid_snapshot"


def test_a_doctype_in_the_xml_is_refused(tmp_path: Path) -> None:
    folder = tmp_path / "evil"
    folder.mkdir()
    (folder / "esklp.xml").write_text(
        '<?xml version="1.0"?><!DOCTYPE esklp [<!ENTITY a "aaaa">]><esklp><klp uuid="x"/></esklp>'
    )

    with pytest.raises(ImporterDataError) as caught:
        _parse(folder)
    assert caught.value.code == "invalid_snapshot"


def test_xml_in_windows_1251_is_read(tmp_path: Path) -> None:
    folder = tmp_path / "cp1251"
    folder.mkdir()
    xml = ru_data.esklp_xml().replace('encoding="UTF-8"', 'encoding="windows-1251"')
    # "Ё" and quotes are in cp1251; nothing else in the fixture needs replacing
    (folder / "esklp.xml").write_bytes(xml.encode("cp1251"))

    records, _ = _parse(folder)

    names = {r.brand_name for r in records if isinstance(r, ProductRecord)}
    assert "Тестамол 500" in names


def test_several_xml_files_are_one_snapshot(tmp_path: Path) -> None:
    folder = tmp_path / "split"
    folder.mkdir()
    whole = ru_data.esklp_xml().splitlines(keepends=True)
    smnn = [line for line in whole if "<smnn" in line]
    klp = [line for line in whole if "<klp" in line]
    head, tail = whole[0] + whole[1], whole[-1]
    (folder / "a-smnn.xml").write_text(head + "".join(smnn) + tail, encoding="utf-8")
    (folder / "b-klp.xml").write_text(head + "".join(klp) + tail, encoding="utf-8")

    split, _ = _parse(folder)

    assert split == _parse(_xml_snapshot(tmp_path))[0]


def test_ambiguous_or_missing_input_is_refused(tmp_path: Path) -> None:
    mixed = _xml_snapshot(tmp_path, "mixed")
    ru_data.esklp_xlsx(mixed / "esklp.xlsx")
    with pytest.raises(ImporterError) as caught:
        _parse(mixed)
    assert caught.value.code == "snapshot_ambiguous"

    empty = tmp_path / "nothing"
    empty.mkdir()
    with pytest.raises(ImporterError) as caught:
        _parse(empty)
    assert caught.value.code == "snapshot_not_found"


def test_a_barcode_printed_on_two_trade_items_belongs_to_neither(tmp_path: Path) -> None:
    folder = _xml_snapshot(tmp_path)
    text = (folder / "esklp.xml").read_text(encoding="utf-8")
    text = text.replace("<barcode></barcode>", "<barcode>4600000000015</barcode>", 1)
    (folder / "esklp.xml").write_text(text, encoding="utf-8")

    records, skipped = _parse(folder)

    products = {r.source_key: r for r in records if isinstance(r, ProductRecord)}
    assert products[uid(101)].packages[0].gtins == ()
    assert products[uid(103)].packages[0].gtins == ()
    assert skipped["gtin_ambiguous"] == 2


def test_an_rxcui_maps_a_single_ingredient_to_the_shared_substance(tmp_path: Path) -> None:
    folder = tmp_path / "book"
    folder.mkdir()
    rows = ru_data.flat_rows()
    rows[0].append("RxNorm")
    for row in rows[1:]:
        row.append("5640" if row[3] in ("Тестамол", "Тестамол + Пробинол") else None)
    build_xlsx(folder / "esklp.xlsx", {"КЛП": rows})

    records, _ = _parse(folder)

    compositions = {r.source_key: r for r in records if isinstance(r, CompositionRecord)}
    assert compositions[uid(1)].ingredients[0].shared_substance == ("rxnorm", "5640")
    assert all(i.shared_substance is None for i in compositions[uid(2)].ingredients)
