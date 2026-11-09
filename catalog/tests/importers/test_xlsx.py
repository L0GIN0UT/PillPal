"""The read-only xlsx reader: values, and every guard of an untrusted workbook."""

from __future__ import annotations

import zipfile
from collections.abc import Callable
from pathlib import Path

import pytest

from catalog.importers.base import ImporterDataError
from catalog.importers.xlsx import Workbook, XlsxLimits, _number_text
from tests.importers.xlsx_support import MAIN_NS, build_xlsx

ROWS = [
    ["Номер РУ", "Название", "Штрихкод"],
    ["ЛП-000001", "Тестамол 500", 4600000000015],
    [None, "Ёлочка", None, "extra"],
    [],
    ["ЛП-000002", None, 4600000000220],
]
Table = list[list[str | None]]


def _read(path: Path, limits: XlsxLimits | None = None) -> Table:
    with Workbook(path, limits or XlsxLimits()) as book:
        return [list(r) for r in book.rows(book.sheet_names[0])]


@pytest.mark.parametrize("inline", [False, True])
def test_values_come_back_as_text_for_shared_and_inline_strings(
    tmp_path: Path, inline: bool
) -> None:
    path = build_xlsx(tmp_path / "a.xlsx", {"КЛП": ROWS}, inline_strings=inline)

    rows = _read(path)

    assert rows[0] == ["Номер РУ", "Название", "Штрихкод"]
    assert rows[1] == ["ЛП-000001", "Тестамол 500", "4600000000015"]
    assert rows[2] == [None, "Ёлочка", None, "extra"]
    assert rows[3] == []
    assert rows[4] == ["ЛП-000002", None, "4600000000220"]


def test_sheets_keep_their_order_and_names(tmp_path: Path) -> None:
    path = build_xlsx(tmp_path / "a.xlsx", {"КЛП": [["a"]], "СМНН": [["b"]]})
    with Workbook(path, XlsxLimits()) as book:
        assert book.sheet_names == ["КЛП", "СМНН"]
        assert [list(r) for r in book.rows("СМНН")] == [["b"]]
        with pytest.raises(ImporterDataError) as caught:
            list(book.rows("missing"))
        assert caught.value.code == "xlsx_invalid"


def test_the_modified_date_is_the_version(tmp_path: Path) -> None:
    path = build_xlsx(tmp_path / "a.xlsx", {"s": [["a"]]}, modified="2026-10-01T08:30:00Z")
    with Workbook(path, XlsxLimits()) as book:
        assert book.modified == "2026-10-01"
    bare = build_xlsx(tmp_path / "b.xlsx", {"s": [["a"]]}, modified=None)
    with Workbook(bare, XlsxLimits()) as book:
        assert book.modified is None


def test_rich_text_cells_drop_phonetic_runs(tmp_path: Path) -> None:
    shared = (
        f'<?xml version="1.0" encoding="UTF-8"?><sst xmlns="{MAIN_NS}"><si><r><t>Тест</t></r>'
        "<r><t>амол</t></r><rPh><t>PHONETIC</t></rPh></si></sst>"
    )
    sheet = (
        f'<worksheet xmlns="{MAIN_NS}"><sheetData><row r="1">'
        '<c r="A1" t="s"><v>0</v></c></row></sheetData></worksheet>'
    )
    path = build_xlsx(
        tmp_path / "b.xlsx",
        {"s": [["x"]]},
        extra_parts={
            "xl/sharedStrings.xml": shared.encode(),
            "xl/worksheets/sheet1.xml": sheet.encode(),
        },
    )
    assert _read(path) == [["Тестамол"]]


def _failing(path: Path, code: str, limits: XlsxLimits | None = None) -> None:
    with pytest.raises(ImporterDataError) as caught:
        _read(path, limits)
    assert caught.value.code == code


def _with_sheet(tmp_path: Path, name: str, sheet: str) -> Path:
    return build_xlsx(
        tmp_path / name, {"s": [["x"]]}, extra_parts={"xl/worksheets/sheet1.xml": sheet.encode()}
    )


def test_a_file_that_is_not_a_workbook_is_refused(tmp_path: Path) -> None:
    junk = tmp_path / "junk.xlsx"
    junk.write_bytes(b"not a zip at all")
    _failing(junk, "xlsx_invalid")

    other = tmp_path / "other.xlsx"
    with zipfile.ZipFile(other, "w") as z:
        z.writestr("hello.txt", "x")
    _failing(other, "xlsx_invalid")


def test_a_truncated_workbook_is_refused(tmp_path: Path) -> None:
    path = build_xlsx(tmp_path / "a.xlsx", {"s": ROWS})
    data = path.read_bytes()
    path.write_bytes(data[: len(data) // 2])
    _failing(path, "xlsx_invalid")


def test_a_doctype_or_entity_is_refused(tmp_path: Path) -> None:
    bomb = (
        '<?xml version="1.0"?><!DOCTYPE s [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;">]>'
        f'<worksheet xmlns="{MAIN_NS}"><sheetData><row r="1">'
        '<c r="A1" t="inlineStr"><is><t>&b;</t></is></c></row></sheetData></worksheet>'
    )
    _failing(_with_sheet(tmp_path, "a.xlsx", bomb), "xlsx_invalid")


def test_a_part_that_inflates_beyond_the_ratio_is_refused(tmp_path: Path) -> None:
    padding = " " * 5_000_000
    sheet = f'<worksheet xmlns="{MAIN_NS}"><sheetData>{padding}</sheetData></worksheet>'
    _failing(_with_sheet(tmp_path, "a.xlsx", sheet), "xlsx_too_large")


def test_the_part_size_cap_counts_bytes_actually_produced(tmp_path: Path) -> None:
    path = build_xlsx(tmp_path / "a.xlsx", {"s": [[f"v{i}"] for i in range(200)]})
    _failing(path, "xlsx_too_large", XlsxLimits(max_part_bytes=500, max_ratio=10_000))


def test_row_column_cell_sheet_and_string_limits(tmp_path: Path) -> None:
    rows = build_xlsx(tmp_path / "r.xlsx", {"s": [[str(i)] for i in range(10)]})
    _failing(rows, "xlsx_too_large", XlsxLimits(max_rows=5))

    wide = build_xlsx(tmp_path / "w.xlsx", {"s": [[str(i) for i in range(10)]]})
    _failing(wide, "xlsx_too_large", XlsxLimits(max_columns=5))

    long_cell = build_xlsx(tmp_path / "c.xlsx", {"s": [["x" * 50]]})
    _failing(long_cell, "xlsx_too_large", XlsxLimits(max_cell_chars=10))

    many = build_xlsx(tmp_path / "m.xlsx", {f"s{i}": [["x"]] for i in range(4)})
    _failing(many, "xlsx_too_large", XlsxLimits(max_sheets=3))

    strings = build_xlsx(tmp_path / "s.xlsx", {"s": [[f"v{i}" for i in range(10)]]})
    _failing(strings, "xlsx_too_large", XlsxLimits(max_shared_strings=5))


def test_a_symlinked_part_is_refused(tmp_path: Path) -> None:
    path = tmp_path / "a.xlsx"
    with zipfile.ZipFile(path, "w") as z:
        link = zipfile.ZipInfo("xl/workbook.xml")
        link.external_attr = 0o120777 << 16
        z.writestr(link, "x")
    _failing(path, "xlsx_invalid")


def test_a_cell_reference_beyond_the_column_limit_is_refused(tmp_path: Path) -> None:
    sheet = (
        f'<worksheet xmlns="{MAIN_NS}"><sheetData><row r="1">'
        '<c r="ZZZZ1" t="inlineStr"><is><t>x</t></is></c></row></sheetData></worksheet>'
    )
    _failing(_with_sheet(tmp_path, "a.xlsx", sheet), "xlsx_too_large")


def test_a_windows_1251_declaration_is_read_and_other_encodings_are_refused(
    tmp_path: Path,
) -> None:
    sheet = (
        '<?xml version="1.0" encoding="windows-1251"?>'
        f'<worksheet xmlns="{MAIN_NS}"><sheetData><row r="1">'
        '<c r="A1" t="inlineStr"><is><t>Тест</t></is></c></row></sheetData></worksheet>'
    )
    ok = build_xlsx(
        tmp_path / "a.xlsx",
        {"s": [["x"]]},
        extra_parts={"xl/worksheets/sheet1.xml": sheet.encode("cp1251")},
    )
    assert _read(ok) == [["Тест"]]

    wide = (f'<?xml version="1.0" encoding="utf-16"?><worksheet xmlns="{MAIN_NS}"/>').encode(
        "utf-16"
    )
    bad = build_xlsx(
        tmp_path / "c.xlsx", {"s": [["x"]]}, extra_parts={"xl/worksheets/sheet1.xml": wide}
    )
    _failing(bad, "xlsx_invalid")


def test_exponent_numbers_become_plain_digits() -> None:
    assert _number_text("4.600000000022E12") == "4600000000022"
    assert _number_text("12.5") == "12.5"
    assert _number_text("1.5E0") == "1.5"
    assert _number_text("nanE") == "nanE"
    assert _number_text("1E999999") == "1E999999"


UTF16_BOMB = f' <!DOCTYPE r [<!ENTITY a "x">]><worksheet xmlns="{MAIN_NS}">&a;</worksheet>'


@pytest.mark.parametrize("encoding", ["utf-16-le", "utf-16-be", "utf-32-le"])
def test_a_doctype_hidden_in_utf16_without_a_bom_is_refused(tmp_path: Path, encoding: str) -> None:
    path = _with_sheet(tmp_path, "a.xlsx", "")
    bomb = build_xlsx(
        tmp_path / "b.xlsx",
        {"s": [["x"]]},
        extra_parts={"xl/worksheets/sheet1.xml": UTF16_BOMB.encode(encoding)},
    )
    assert path.exists()
    _failing(bomb, "xlsx_invalid")


def _spy_roots(monkeypatch: pytest.MonkeyPatch, module: object) -> list[object]:
    """Remember the first element every ``iterparse`` call of ``module`` produces (its root)."""
    roots: list[object] = []
    real: Callable[..., object] = module.iterparse  # type: ignore[attr-defined]

    def wrapper(stream: object, events: tuple[str, ...]):  # type: ignore[no-untyped-def]
        first = True
        for event, element in real(stream, events):  # type: ignore[attr-defined]
            if first:
                roots.append(element)
                first = False
            yield event, element

    monkeypatch.setattr(module, "iterparse", wrapper)
    return roots


def test_junk_elements_do_not_pile_up_while_a_sheet_is_streamed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import catalog.importers.xlsx as xlsx_module

    junk = "<junk/>" * 5000
    sheet = (
        f'<worksheet xmlns="{MAIN_NS}"><sheetData><row r="1">{junk}'
        '<c r="A1" t="inlineStr"><is><t>x</t></is></c></row></sheetData>'
        f"{junk}</worksheet>"
    )
    shared = f'<sst xmlns="{MAIN_NS}">{junk}<si><t>a</t></si>{junk}</sst>'
    path = build_xlsx(
        tmp_path / "a.xlsx",
        {"s": [["x"]]},
        extra_parts={
            "xl/worksheets/sheet1.xml": sheet.encode(),
            "xl/sharedStrings.xml": shared.encode(),
        },
    )
    roots = _spy_roots(monkeypatch, xlsx_module)

    assert _read(path) == [["x"]]

    sst_root, sheet_root = roots[-2], roots[-1]
    assert len(sst_root) == 0  # type: ignore[arg-type]
    assert len(sheet_root) <= 1  # type: ignore[arg-type]  # only the sheetData element


def test_a_huge_exponent_number_is_left_alone() -> None:
    assert _number_text("1E29") == "100000000000000000000000000000"


def test_the_total_bytes_read_from_a_workbook_are_budgeted(tmp_path: Path) -> None:
    path = build_xlsx(tmp_path / "a.xlsx", {"s": [[f"value-{i}"] for i in range(100)]})
    _failing(path, "xlsx_too_large", XlsxLimits(max_total_bytes=600))


TRAILERS = (
    '<conditionalFormatting sqref="A1"><cfRule type="expression" priority="1">'
    "<formula>A1&gt;1</formula></cfRule></conditionalFormatting>"
    '<dataValidations count="1"><dataValidation type="list"><formula1>"a,b"</formula1>'
    "</dataValidation></dataValidations>"
    '<extLst><ext uri="{x}"><x14:y xmlns:x14="urn:x">1</x14:y></ext></extLst>'
)


def test_real_world_elements_after_the_sheet_data_are_ignored(tmp_path: Path) -> None:
    sheet = (
        f'<worksheet xmlns="{MAIN_NS}"><sheetData><row r="1">'
        '<c r="A1" t="inlineStr"><is><t>x</t></is></c></row>'
        f'<row r="2"><c r="A2" t="inlineStr"><is><t>y</t></is></c></row></sheetData>{TRAILERS}'
        "</worksheet>"
    )
    path = _with_sheet(tmp_path, "a.xlsx", sheet)

    assert _read(path) == [["x"], ["y"]]


def test_non_row_children_and_trailers_do_not_pile_up(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import catalog.importers.xlsx as xlsx_module

    merged = '<mergeCell ref="A1:B2"/>' * 5000
    sheet = (
        f'<worksheet xmlns="{MAIN_NS}"><sheetData><junk/>'
        + "<junk/>" * 5000
        + '<row r="1"><c r="A1" t="inlineStr"><is><t>x</t></is></c></row>'
        + "<junk/>" * 5000
        + f"</sheetData><mergeCells>{merged}</mergeCells>{TRAILERS}</worksheet>"
    )
    path = _with_sheet(tmp_path, "a.xlsx", sheet)
    roots = _spy_roots(monkeypatch, xlsx_module)

    assert _read(path) == [["x"]]

    assert len(roots[-1]) == 0  # type: ignore[arg-type]
