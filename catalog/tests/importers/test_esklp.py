"""The ESKLP importer: refusal while the flag is off, parsing of the XML and xlsx shapes into
the same records, the counted drops, and the guards on a snapshot that is incomplete."""

from __future__ import annotations

from pathlib import Path
from xml.etree import ElementTree as ET

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
from catalog.importers.esklp_source import MAX_RECORD_ELEMENTS, MAX_XML_DEPTH, iter_items
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
    assert first.packages[0].description == "блистер (10), пачка (1)"
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
        "manufacturer_individual": 1,
        "gtin_invalid": 1,
        "gtin_restricted": 1,
    }


def test_the_manufacturer_is_the_published_name_and_never_the_address(tmp_path: Path) -> None:
    records, _ = _parse(_xml_snapshot(tmp_path))

    forte = next(r for r in records if isinstance(r, ProductRecord) and r.source_key == uid(102))
    assert forte.manufacturer is None  # an individual entrepreneur is a natural person
    assert ru_data.IE_NAME not in repr(records)
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


def test_the_version_is_the_root_date_create_or_the_workbook_date(tmp_path: Path) -> None:
    assert _importer().snapshot_version(_xml_snapshot(tmp_path)) == ru_data.ESKLP_VERSION
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
    first, second = ru_data.GROUPS
    (folder / "a.xml").write_text(ru_data.esklp_xml([first]), encoding="utf-8")
    (folder / "b.xml").write_text(ru_data.esklp_xml([second]), encoding="utf-8")

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
    lines = (folder / "esklp.xml").read_text(encoding="utf-8").splitlines(keepends=True)
    price = "<ns2:klp_lim_price><ns2:barcode>4600000000015</ns2:barcode></ns2:klp_lim_price>"
    claimed = f"<ns2:klp_lim_price_list>{price}</ns2:klp_lim_price_list></ns2:klp>"
    # Ёжикаин (uid 103) printed no barcode; now a price record of it claims Тестамол's
    lines = [line.replace("</ns2:klp>", claimed) if uid(103) in line else line for line in lines]
    (folder / "esklp.xml").write_text("".join(lines), encoding="utf-8")

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


def test_a_doctype_hidden_in_utf16_is_refused(tmp_path: Path) -> None:
    bomb = ' <!DOCTYPE esklp [<!ENTITY a "x">]><esklp><klp uuid="x">&a;</klp></esklp>'
    for encoding in ("utf-16-le", "utf-16-be"):
        folder = tmp_path / encoding
        folder.mkdir()
        (folder / "esklp.xml").write_bytes(bomb.encode(encoding))
        with pytest.raises(ImporterDataError) as caught:
            _parse(folder)
        assert caught.value.code == "invalid_snapshot"


def test_junk_elements_do_not_pile_up_while_the_xml_is_streamed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import catalog.importers.esklp_source as source_module

    roots: list[object] = []
    real = source_module.iterparse

    def wrapper(stream: object, events: tuple[str, ...]):  # type: ignore[no-untyped-def]
        first = True
        for event, element in real(stream, events):  # type: ignore[arg-type]
            if first:
                roots.append(element)
                first = False
            yield event, element

    monkeypatch.setattr(source_module, "iterparse", wrapper)
    folder = _xml_snapshot(tmp_path)
    text = (folder / "esklp.xml").read_text(encoding="utf-8")
    junk = "<junk><deep/></junk>" * 3000
    text = text.replace("</ns2:ESKLP>", f"<wrapper>{junk}</wrapper>{junk}</ns2:ESKLP>")
    (folder / "esklp.xml").write_text(text, encoding="utf-8")

    records, _ = _parse(folder)

    assert len(records) > 6
    assert len(roots[-1]) == 0  # type: ignore[arg-type]  # the streaming pass


def test_a_missing_smnn_sheet_is_not_skipped_silently(tmp_path: Path) -> None:
    folder = tmp_path / "book"
    folder.mkdir()
    klp = [["KLP UUID", "SMNN UUID", "Торговое наименование"]]
    klp += [[uid(101), uid(1), "Тестамол 500"]]
    smnn = [["SMNN UUID", "Вещество", "Форма"], [uid(1), "Тестамол", "таблетки"]]  # unknown headers
    build_xlsx(folder / "esklp.xlsx", {"КЛП": klp, "СМНН": smnn})

    with pytest.raises(ImporterDataError) as caught:
        _parse(folder)
    assert caught.value.code == "missing_sheet"


def test_an_invalid_trade_item_cannot_claim_a_barcode(tmp_path: Path) -> None:
    folder = tmp_path / "book"
    folder.mkdir()
    rows = ru_data.flat_rows([ru_data.KLP[0]])
    bad = list(rows[1])
    bad[0], bad[2] = uid(190), ""  # a KLP without a trade name, same barcode as the valid one
    build_xlsx(folder / "esklp.xlsx", {"КЛП": [rows[0], bad, rows[1]]})

    records, skipped = _parse(folder)

    products = [r for r in records if isinstance(r, ProductRecord)]
    assert [p.packages[0].gtins for p in products] == [("04600000000015",)]
    assert skipped["invalid_klp"] == 1


def _items(folder: Path) -> list[tuple[str, dict[str, str | None]]]:
    return list(iter_items(folder))


def test_each_smnn_and_each_nested_klp_is_a_row_linked_by_nesting(tmp_path: Path) -> None:
    items = _items(_xml_snapshot(tmp_path))

    smnn = {row["smnn_uuid"]: row for kind, row in items if kind == "smnn"}
    assert set(smnn) == {uid(1), uid(2), uid(3), uid(4), uid(5), uid(99)}
    assert smnn[uid(2)]["inn"] == "Тестамол + Пробинол"  # from <mnn>
    assert smnn[uid(2)]["dosage"] == "250 мг+125 мг"  # dosage/grls_value
    assert smnn[uid(2)]["form"] == "таблетки, покрытые пленочной оболочкой"
    klp = [row for kind, row in items if kind == "klp"]
    assert [row["klp_uuid"] for row in klp[:3]] == [uid(101), uid(107), uid(101)]
    first = klp[0]
    assert first["smnn_uuid"] == uid(1)  # the enclosing <smnn>, not an attribute
    assert first["country"] == "Россия"  # manufacturer/country_name
    assert (first["pack_1"], first["pack_2"]) == ("блистер (10)", "пачка (1)")
    ramolin = next(row for row in klp if row["klp_uuid"] == uid(105))
    assert ramolin["barcode"] == "4600000000022;4600000000077"  # distinct, from price records
    assert first["manufacturer"] == ru_data.MAKER  # not the owner (an invented IE) before it
    assert ru_data.IE_ADDRESS not in repr(items)


def test_a_klp_outside_an_smnn_has_no_composition(tmp_path: Path) -> None:
    folder = tmp_path / "flat"
    folder.mkdir()
    lines = ru_data.esklp_xml().splitlines(keepends=True)
    stray = next(line for line in lines if uid(103) in line)
    stray = stray.replace("<ns2:klp ", f'<ns2:klp smnn_uuid="{uid(3)}" ', 1)
    text = "".join(lines).replace("</ns2:ESKLP>", f"{stray}</ns2:ESKLP>")
    (folder / "esklp.xml").write_text(text.replace(uid(103), uid(108), 1), encoding="utf-8")

    rows = {row["klp_uuid"]: row for kind, row in _items(folder) if kind == "klp"}

    assert rows[uid(103)]["smnn_uuid"] is None  # an attribute is not a link
    assert rows[uid(108)]["smnn_uuid"] == uid(3)


@pytest.mark.parametrize(
    ("dosage", "expected"),
    [
        ("<ns2:grls_value>500 мг</ns2:grls_value>", "500 мг"),
        (
            "<ns2:grls_value> </ns2:grls_value><ns2:dosage_unit><ns2:name>мг</ns2:name>"
            "</ns2:dosage_unit><ns2:dosage_num>2.5000000000</ns2:dosage_num>",
            "2.5 мг",
        ),
        ("<ns2:dosage_num>7</ns2:dosage_num>", None),
        ("", None),
    ],
)
def test_the_dosage_is_the_grls_value_or_the_number_and_unit(
    tmp_path: Path, dosage: str, expected: str | None
) -> None:
    folder = tmp_path / "d"
    folder.mkdir()
    (folder / "esklp.xml").write_text(
        '<?xml version="1.0"?><ns2:ESKLP xmlns:ns2="urn:x" date_create="1">'
        f'<ns2:smnn UUID="{uid(1)}"><ns2:mnn>Тестамол</ns2:mnn>'
        f"<ns2:dosage>{dosage}</ns2:dosage></ns2:smnn></ns2:ESKLP>",
        encoding="utf-8",
    )
    [(_, row)] = _items(folder)
    assert row["dosage"] == expected


def _nested(depth: int) -> str:
    """``depth`` nested groups around one СМНН with one КЛП (a barcode in a price record)."""
    group: ru_data.Group = ("Г", [uid(1)], [])
    for _ in range(depth - 1):
        group = ("Г", [], [group])
    return ru_data.esklp_xml([group])


def test_realistically_nested_groups_are_read(tmp_path: Path) -> None:
    folder = tmp_path / "deep"
    folder.mkdir()
    (folder / "esklp.xml").write_text(_nested(10), encoding="utf-8")

    klp = [row for kind, row in _items(folder) if kind == "klp"]

    assert klp[0]["klp_uuid"] == uid(101)
    assert klp[0]["smnn_uuid"] == uid(1)
    assert klp[0]["barcode"] == "4600000000015"  # 10 groups + price record: depth 28


def test_runaway_nesting_is_refused(tmp_path: Path) -> None:
    folder = tmp_path / "deeper"
    folder.mkdir()
    (folder / "esklp.xml").write_text(_nested(MAX_XML_DEPTH), encoding="utf-8")

    with pytest.raises(ImporterDataError) as caught:
        _items(folder)
    assert caught.value.code == "invalid_snapshot"


def test_many_trade_items_do_not_accumulate_while_streamed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import catalog.importers.esklp_source as source_module

    lists: list[ET.Element] = []
    real = source_module.iterparse

    def watching(stream: object, events: tuple[str, ...]):  # type: ignore[no-untyped-def]
        for event, element in real(stream, events):  # type: ignore[arg-type]
            if event == "start" and element.tag.endswith("}klp_list"):
                lists.append(element)
            yield event, element

    monkeypatch.setattr(source_module, "iterparse", watching)
    count = 5000
    template = next(line for line in ru_data.esklp_xml().splitlines() if uid(101) in line)
    many = "\n".join(template.replace(uid(101), uid(10_000 + n)) for n in range(count))
    folder = tmp_path / "many"
    folder.mkdir()
    (folder / "esklp.xml").write_text(
        ru_data.esklp_xml([("Г", [uid(1)], [])]).replace(template, many), encoding="utf-8"
    )

    seen = 0
    for kind, _ in iter_items(folder):
        seen += kind == "klp"
        # each КЛП is dropped once read: only those the parser has buffered ahead remain
        assert max(len(element) for element in lists) <= 64

    assert seen == count + 2  # plus the nameless and the repeated КЛП of the fixture


def _root(attributes: str, body: str = "") -> str:
    return (
        f'<?xml version="1.0"?><ns2:ESKLP xmlns:ns2="urn:x" date_create="1" {attributes}>'
        f"{body}</ns2:ESKLP>"
    )


@pytest.mark.parametrize("content_type", ["full", "increment", ""])
def test_only_a_full_active_export_is_accepted(tmp_path: Path, content_type: str) -> None:
    folder = _xml_snapshot(tmp_path)
    xml = (folder / "esklp.xml").read_text(encoding="utf-8")
    bad = xml.replace('contentType="fullActive"', f'contentType="{content_type}"')
    (folder / "esklp.xml").write_text(bad, encoding="utf-8")

    with pytest.raises(ImporterDataError) as caught:
        _items(folder)
    assert caught.value.code == "snapshot_not_full"
    with pytest.raises(ImporterDataError):
        _importer().snapshot_version(folder)


def _parts(tmp_path: Path, *parts: str) -> Path:
    folder = tmp_path / "parts"
    folder.mkdir(parents=True)
    first, second = ru_data.GROUPS
    groups = [[first], [second], [first]]
    for n, attributes in enumerate(parts):
        xml = ru_data.esklp_xml(groups[n]).replace(
            'contentType="fullActive"', f'contentType="fullActive" {attributes}'
        )
        (folder / f"part{n}.xml").write_text(xml, encoding="utf-8")
    return folder


def test_a_split_export_needs_every_part_exactly_once(tmp_path: Path) -> None:
    whole = _parts(tmp_path, 'partNumber="2" partQuantity="2"', 'partNumber="1" partQuantity="2"')
    assert _parse(whole)[0] == _parse(_xml_snapshot(tmp_path))[0]

    for name, parts in {
        "missing": ['partNumber="1" partQuantity="2"'],
        "twice": ['partNumber="1" partQuantity="2"', 'partNumber="1" partQuantity="2"'],
        "disagree": ['partNumber="1" partQuantity="2"', 'partNumber="2" partQuantity="3"'],
        "unnumbered": ['partQuantity="2"', 'partNumber="2" partQuantity="2"'],
        "mixed": ['partNumber="1" partQuantity="2"', ""],
        "junk": ['partNumber="x" partQuantity="1"'],
    }.items():
        with pytest.raises(ImporterDataError) as caught:
            _items(_parts(tmp_path / name, *parts))
        assert caught.value.code == "snapshot_parts_mismatch", name


def test_a_version_with_a_time_zone_offset_is_kept(tmp_path: Path) -> None:
    folder = tmp_path / "tz"
    folder.mkdir()
    xml = ru_data.esklp_xml().replace(ru_data.ESKLP_VERSION, "2026-10-01T03:00:00+03:00")
    (folder / "esklp.xml").write_text(xml, encoding="utf-8")
    assert _importer().snapshot_version(folder) == "2026-10-01T03:00:00+03:00"


def test_a_pack_without_a_name_keeps_its_number(tmp_path: Path) -> None:
    folder = tmp_path / "pack"
    folder.mkdir()
    klp = (
        f'<ns2:smnn UUID="{uid(1)}"><ns2:mnn>Тестамол</ns2:mnn><ns2:klp_list>'
        f'<ns2:klp UUID="{uid(101)}"><ns2:trade_name>Т</ns2:trade_name>'
        "<ns2:pack_1><ns2:num>10.0</ns2:num></ns2:pack_1>"
        "<ns2:pack_2><ns2:num>0</ns2:num><ns2:name>пачка</ns2:name></ns2:pack_2>"
        "</ns2:klp></ns2:klp_list></ns2:smnn>"
    )
    (folder / "esklp.xml").write_text(_root("", klp), encoding="utf-8")
    [(_, row)] = [item for item in _items(folder) if item[0] == "klp"]
    assert (row["pack_1"], row["pack_2"]) == ("10", "пачка")


def test_a_record_with_runaway_content_is_refused(tmp_path: Path) -> None:
    folder = tmp_path / "fat"
    folder.mkdir()
    junk = "<ns2:ath><ns2:ath_code>A</ns2:ath_code></ns2:ath>" * (MAX_RECORD_ELEMENTS // 2 + 1)
    smnn = f'<ns2:smnn UUID="{uid(1)}"><ns2:mnn>Тестамол</ns2:mnn>{junk}</ns2:smnn>'
    (folder / "esklp.xml").write_text(_root("", smnn), encoding="utf-8")

    with pytest.raises(ImporterDataError) as caught:
        _items(folder)
    assert caught.value.code == "invalid_snapshot"


def test_many_smnn_in_one_group_do_not_accumulate_while_streamed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import catalog.importers.esklp_source as source_module

    lists: list[ET.Element] = []
    real = source_module.iterparse

    def watching(stream: object, events: tuple[str, ...]):  # type: ignore[no-untyped-def]
        for event, element in real(stream, events):  # type: ignore[arg-type]
            if event == "start" and element.tag.endswith(("}smnn_list", "}klp_list")):
                lists.append(element)
            yield event, element

    monkeypatch.setattr(source_module, "iterparse", watching)
    count = 3000
    ru_data_smnn = [(uid(50_000 + n), "Тестамол", "таблетки", "500 мг") for n in range(count)]
    monkeypatch.setattr(ru_data, "SMNN", ru_data.SMNN + ru_data_smnn)
    folder = tmp_path / "many"
    folder.mkdir()
    keys = [s[0] for s in ru_data_smnn]
    (folder / "esklp.xml").write_text(ru_data.esklp_xml([("Г", keys, [])]), encoding="utf-8")

    seen = 0
    for kind, _ in iter_items(folder):
        seen += kind == "smnn"
        # every list (of СМНН, of КЛП) holds only what the parser has buffered ahead
        assert max(len(element) for element in lists) <= 64

    assert seen == count
