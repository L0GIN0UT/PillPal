"""Reading an ESKLP snapshot directory into plain rows (no catalog logic here).

Two input shapes are supported, both ending in the same row dictionaries:

- one ``.xlsx`` workbook (the portal's "whole catalog" file): a sheet is recognised by its header,
  not its name. A sheet with a KLP key and a trade name holds trade items (and may repeat the INN,
  form and dosage columns of its SMNN); a sheet with an SMNN key and an INN holds SMNN rows;
- one or several ``.xml`` files per the ESKLP passport: ``<smnn>`` and ``<klp>`` elements (any
  nesting), fields as child elements or attributes.

FORMAT STATUS: written from the passport description in docs/research/ru-sources.md and verified
only against synthetic fixtures. The header aliases and element names are the first thing to check
against a real file during the owner's smoke import (docs/phase4-plan.md 4.4b checklist).

Only the fields the catalog needs are read. The manufacturer's address and every other column are
never copied, so personal data a register may print for an individual entrepreneur cannot reach
the importer.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from pathlib import Path
from xml.etree import ElementTree as ET

from catalog.importers.base import ImporterDataError, ImporterError
from catalog.importers.safe_xml import GuardedStream, iterparse, local_name
from catalog.importers.tabular import cell, find_columns, fold_aliases
from catalog.importers.xlsx import Workbook, XlsxLimits

Row = dict[str, str | None]
Item = tuple[str, Row]
KLP, SMNN = "klp", "smnn"

# canonical field -> header wordings (compared folded: case, ё, spaces and punctuation ignored)
ALIASES = fold_aliases(
    {
        "klp_uuid": ["KLP UUID", "KLP.UUID", "UUID КЛП", "Идентификатор КЛП", "Код КЛП"],
        "smnn_uuid": ["SMNN UUID", "SMNN.UUID", "UUID СМНН", "Идентификатор СМНН", "Код СМНН"],
        "trade_name": ["trade_name", "Торговое наименование", "Торговое название"],
        "inn": ["МНН", "INN", "Международное непатентованное наименование"],
        "form": ["Лекарственная форма", "Форма выпуска", "Dosage form"],
        "dosage": ["Дозировка", "Dosage"],
        "manufacturer": ["Производитель", "Наименование производителя", "Manufacturer"],
        "country": ["Страна производителя", "Страна", "Country"],
        "num_reg": ["num_reg", "Номер РУ", "Номер регистрационного удостоверения", "№ РУ"],
        "barcode": ["barcode", "Штрихкод", "Штрих-код", "Штрих код", "EAN", "GTIN"],
        "pack_1": ["pack_1", "Первичная упаковка"],
        "pack_2": ["pack_2", "Потребительская упаковка"],
        "rxcui": ["rxcui", "RxNorm"],
    }
)
KLP_REQUIRED = ("klp_uuid", "trade_name")
SMNN_REQUIRED = ("smnn_uuid", "inn")
HEADER_SCAN_ROWS = 5
MAX_XML_FILES = 50
MAX_XML_FILE_BYTES = 2 * 1024**3
MAX_XML_DEPTH = 12
_VERSION = re.compile(r"[0-9A-Za-z._:-]{1,64}", re.ASCII)
_KLP_CHILDREN = ("trade_name", "num_reg", "barcode", "pack_1", "pack_2", "rxcui")
_SMNN_CHILDREN = ("inn", "form", "dosage")


def locate(snapshot_dir: Path) -> tuple[str, list[Path]]:
    """The input files: exactly one workbook, or up to ``MAX_XML_FILES`` XML files, not both."""
    files = sorted(p for p in snapshot_dir.rglob("*") if p.is_file() and not p.is_symlink())
    books = [p for p in files if p.suffix.lower() == ".xlsx"]
    xmls = [p for p in files if p.suffix.lower() == ".xml"]
    if (books and xmls) or len(books) > 1 or len(xmls) > MAX_XML_FILES:
        raise ImporterError("snapshot_ambiguous")
    if books:
        return "xlsx", books
    if xmls:
        return "xml", xmls
    raise ImporterError("snapshot_not_found")


def _find_header(rows: Iterator[list[str | None]]) -> tuple[str, dict[str, int]] | None:
    """Consumes rows up to the header; ``None`` when the sheet has no recognisable header."""
    for position, row in enumerate(rows):
        columns = find_columns(row, ALIASES)
        if all(f in columns for f in KLP_REQUIRED):
            return KLP, columns
        if all(f in columns for f in SMNN_REQUIRED):
            return SMNN, columns
        if position + 1 >= HEADER_SCAN_ROWS:
            break
    return None


def _xlsx_items(path: Path) -> Iterator[Item]:
    recognised = False
    with Workbook(path, XlsxLimits()) as book:
        for name in book.sheet_names:
            rows = iter(book.rows(name))
            header = _find_header(rows)
            if header is None:
                continue
            recognised = True
            kind, columns = header
            for row in rows:
                yield kind, {field: cell(row, columns, field) for field in columns}
    if not recognised:
        raise ImporterDataError("missing_columns")


def _attribute(element: ET.Element, *names: str) -> str | None:
    wanted = set(names)
    return next((v for k, v in element.attrib.items() if local_name(k).lower() in wanted), None)


def _child(element: ET.Element, name: str) -> ET.Element | None:
    return next((c for c in element if local_name(c.tag).lower() == name), None)


def _text(element: ET.Element, name: str) -> str | None:
    found = _child(element, name)
    return None if found is None else found.text


def _uuid_of(element: ET.Element, prefix: str) -> str | None:
    return _attribute(element, f"{prefix}_uuid", "uuid") or _text(element, f"{prefix}_uuid")


def _smnn_row(element: ET.Element) -> Row:
    row: Row = {"smnn_uuid": _uuid_of(element, "smnn")}
    row.update({name: _text(element, name) for name in _SMNN_CHILDREN})
    return row


def _klp_row(element: ET.Element) -> Row:
    row: Row = {"klp_uuid": _uuid_of(element, "klp")}
    reference = _child(element, SMNN)
    row["smnn_uuid"] = (
        _attribute(element, "smnn_uuid")
        or _text(element, "smnn_uuid")
        or (None if reference is None else _attribute(reference, "uuid") or reference.text)
    )
    row.update({name: _text(element, name) for name in (*_KLP_CHILDREN, *_SMNN_CHILDREN)})
    maker = _child(element, "manufacturer")
    if maker is not None:
        # The address, and anything else printed next to the name, is deliberately not read.
        row["manufacturer"] = _text(maker, "name") if len(maker) else maker.text
        row["country"] = _text(maker, "country")
    return row


def _xml_items(path: Path) -> Iterator[Item]:
    depth = 0
    in_klp = False
    try:
        with path.open("rb") as raw:
            guarded = GuardedStream(
                raw, MAX_XML_FILE_BYTES, "snapshot_too_large", "invalid_snapshot"
            )
            for event, element in iterparse(guarded, ("start", "end")):
                name = local_name(element.tag).lower()
                if event == "start":
                    depth += 1
                    if depth > MAX_XML_DEPTH:
                        raise ImporterDataError("invalid_snapshot")
                    in_klp = in_klp or name == KLP
                    continue
                depth -= 1
                if name == KLP:
                    in_klp = False
                    yield KLP, _klp_row(element)
                    element.clear()
                elif name == SMNN and not in_klp:
                    yield SMNN, _smnn_row(element)
                    element.clear()
    except ET.ParseError:
        raise ImporterDataError("invalid_snapshot") from None


def iter_items(snapshot_dir: Path) -> Iterator[Item]:
    """``("smnn" | "klp", row)`` pairs of the snapshot; callable again for another pass."""
    kind, files = locate(snapshot_dir)
    for path in files:
        yield from _xlsx_items(path) if kind == "xlsx" else _xml_items(path)


def read_version(snapshot_dir: Path) -> str | None:
    """The workbook's modification day, or the root ``version`` / ``date`` of the first XML."""
    kind, files = locate(snapshot_dir)
    if kind == "xlsx":
        with Workbook(files[0], XlsxLimits()) as book:
            return book.modified
    try:
        with files[0].open("rb") as raw:
            guarded = GuardedStream(
                raw, MAX_XML_FILE_BYTES, "snapshot_too_large", "invalid_snapshot"
            )
            for _, element in iterparse(guarded, ("start",)):
                found = _attribute(element, "version", "date")
                return found if found and _VERSION.fullmatch(found) else None
    except ET.ParseError:
        raise ImporterDataError("invalid_snapshot") from None
    return None
