"""Reading an ESKLP snapshot directory into plain rows (no catalog logic here).

Two input shapes are supported, both ending in the same row dictionaries:

- one ``.xlsx`` workbook (the portal's "whole catalog" file): a sheet is recognised by its header,
  not its name. A sheet with a KLP key and a trade name holds trade items (and may repeat the INN,
  form and dosage columns of its SMNN); a sheet with an SMNN key and an INN holds SMNN rows;
- one or several ``.xml`` files of the portal's XML export (schema ``ESKLP_21.5.xsd``, any
  namespace prefix): each ``<smnn>`` and each ``<klp>`` nested in it is one row.

FORMAT STATUS: the XML side follows the official schema 21.5 (element names, nesting, composite
``dosage`` / ``pack_*`` / ``manufacturer``, barcodes in the ЖНВЛП price records); fixtures are
synthetic files of that shape. The workbook header aliases are still unverified against a real file.

Only the fields the catalog needs are read. The manufacturer's address and every other column are
never copied, so personal data a register may print for an individual entrepreneur cannot reach
the importer.
"""

from __future__ import annotations

import re
from collections.abc import Iterator
from decimal import Decimal, InvalidOperation
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
# ESKLP > group_list > group is 3 levels, each nested group adds 2 and a barcode sits 7 below
# its group: 32 leaves room for 11 nested groups and still refuses runaway nesting.
MAX_XML_DEPTH = 32
# Elements one СМНН (its own fields) or one КЛП may hold while open: real records have a few
# dozen; a record that never ends must not hold the whole file in memory.
MAX_RECORD_ELEMENTS = 10_000
FULL_EXPORT = "fullActive"  # contentType of the full export of active positions
_VERSION = re.compile(r"[0-9A-Za-z._:+-]{1,64}", re.ASCII)


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


def _children(element: ET.Element, name: str) -> Iterator[ET.Element]:
    return (c for c in element if local_name(c.tag).lower() == name)


def _text(element: ET.Element | None, name: str) -> str | None:
    found = None if element is None else _child(element, name)
    return None if found is None or found.text is None else found.text.strip() or None


def _number(text: str | None) -> str | None:
    """A decimal as printed in schema 21.5 (``2.5000000000``) -> ``2.5``; anything else: None."""
    try:
        value = Decimal(text or "")
    except InvalidOperation:
        return None
    return format(value.normalize(), "f") if value.is_finite() and value > 0 else None


def _dosage(smnn: ET.Element) -> str | None:
    """``dosage/grls_value`` (the registered wording, ``250 мг+125 мг``), else ``dosage_num`` and
    ``dosage_unit/name`` (one strength); both missing: unknown."""
    dosage = _child(smnn, "dosage")
    if dosage is None:
        return None
    if printed := _text(dosage, "grls_value"):
        return printed
    number, unit = (
        _number(_text(dosage, "dosage_num")),
        _text(_child(dosage, "dosage_unit"), "name"),
    )
    return f"{number} {unit}" if number and unit else None


def _pack(klp: ET.Element, name: str) -> str | None:
    """``pack_1`` / ``pack_2`` as ``name (num)``: ``блистер (10)``."""
    pack = _child(klp, name)
    label, number = _text(pack, "name"), _number(_text(pack, "num"))
    if label and number:
        return f"{label} ({number})"
    return label or number


def _barcodes(klp: ET.Element) -> str | None:
    """Every distinct barcode of the КЛП, ``;``-joined. Schema 21.5 prints them only in the
    ЖНВЛП price records (``klp_lim_price_list/klp_lim_price/barcode``); a direct child is read
    too. Validation and the per-package cap are ``parse_barcodes``'s."""
    prices = (p for lists in _children(klp, "klp_lim_price_list") for p in lists)
    found = [_text(klp, "barcode")] + [_text(p, "barcode") for p in prices]
    distinct = dict.fromkeys(b for b in found if b)
    return ";".join(distinct) or None


def _smnn_row(element: ET.Element) -> Row:
    return {
        "smnn_uuid": _attribute(element, "uuid"),
        "inn": _text(element, "mnn"),
        "form": _text(element, "form"),
        "dosage": _dosage(element),
    }


def _klp_row(element: ET.Element, smnn_uuid: str | None) -> Row:
    # Only the manufacturer's name and country: its address, and the owner block (which may
    # name an individual entrepreneur), are never read.
    maker = _child(element, "manufacturer")
    return {
        "klp_uuid": _attribute(element, "uuid"),
        "smnn_uuid": smnn_uuid,
        "trade_name": _text(element, "trade_name"),
        "num_reg": _text(element, "num_reg"),
        "manufacturer": _text(maker, "name"),
        "country": _text(maker, "country_name"),
        "pack_1": _pack(element, "pack_1"),
        "pack_2": _pack(element, "pack_2"),
        "barcode": _barcodes(element),
    }


def _xml_items(path: Path) -> Iterator[Item]:
    """Stream ``smnn`` and ``klp`` rows (schema 21.5: ``ESKLP > group_list > group >
    [group_list > group]* > smnn_list > smnn > klp_list > klp``).

    Memory stays bounded however large the file: a КЛП is read when it ends and then removed
    from its list, an СМНН keeps only its own fields until it ends, and whatever ends outside
    both is removed at once. A КЛП belongs to the СМНН it is nested in; an КЛП outside any СМНН
    has none. The СМНН row comes after its КЛП rows (the importer reads all rows first)."""
    stack: list[ET.Element] = []
    smnn: list[ET.Element] = []  # the open СМНН, innermost last
    klp: ET.Element | None = None
    held = [0, 0]  # elements held by the open СМНН (outside a КЛП) and by the open КЛП
    try:
        with path.open("rb") as raw:
            guarded = GuardedStream(
                raw, MAX_XML_FILE_BYTES, "snapshot_too_large", "invalid_snapshot"
            )
            for event, element in iterparse(guarded, ("start", "end")):
                if event == "start":
                    stack.append(element)
                    if len(stack) > MAX_XML_DEPTH:
                        raise ImporterDataError("invalid_snapshot")
                    name = local_name(element.tag).lower()
                    if klp is None and name == SMNN:
                        smnn.append(element)
                    elif klp is None and name == KLP:
                        klp, held[1] = element, 0
                    elif klp is not None or smnn:
                        _hold(held, 1 if klp is not None else 0)
                    continue
                stack.pop()
                if element is klp:
                    klp = None
                    yield KLP, _klp_row(element, _attribute(smnn[-1], "uuid") if smnn else None)
                elif klp is not None or (smnn and element is not smnn[-1]):
                    continue  # a field of the record being read
                elif smnn:
                    smnn.pop()
                    held[0] = 0
                    yield SMNN, _smnn_row(element)
                if stack:
                    stack[-1].remove(element)
    except ET.ParseError:
        raise ImporterDataError("invalid_snapshot") from None


def _hold(held: list[int], slot: int) -> None:
    held[slot] += 1
    if held[slot] > MAX_RECORD_ELEMENTS:
        raise ImporterDataError("invalid_snapshot")


def _root_of(path: Path) -> dict[str, str]:
    """The root element's attributes (local names, lower case)."""
    try:
        with path.open("rb") as raw:
            guarded = GuardedStream(
                raw, MAX_XML_FILE_BYTES, "snapshot_too_large", "invalid_snapshot"
            )
            for _, element in iterparse(guarded, ("start",)):
                return {local_name(k).lower(): v for k, v in element.attrib.items()}
    except ET.ParseError:
        raise ImporterDataError("invalid_snapshot") from None
    return {}


def _check_roots(files: list[Path]) -> list[dict[str, str]]:
    """Only the full export of active positions may be loaded (the importer withdraws what a
    snapshot lacks, so an increment or a part would withdraw the rest); a split export must
    bring every ``partNumber`` 1..``partQuantity`` exactly once."""
    roots = [_root_of(path) for path in files]
    if any(r.get("contenttype", FULL_EXPORT) != FULL_EXPORT for r in roots):
        raise ImporterDataError("snapshot_not_full")
    quantities = {r.get("partquantity") for r in roots}
    if quantities != {None}:
        try:
            (quantity,) = (int(q or "") for q in quantities)
            numbers = sorted(int(r.get("partnumber", "")) for r in roots)
        except ValueError:
            raise ImporterDataError("snapshot_parts_mismatch") from None
        if numbers != list(range(1, quantity + 1)):
            raise ImporterDataError("snapshot_parts_mismatch")
    return roots


def iter_items(snapshot_dir: Path) -> Iterator[Item]:
    """``("smnn" | "klp", row)`` pairs of the snapshot; callable again for another pass."""
    kind, files = locate(snapshot_dir)
    if kind == "xml":
        _check_roots(files)
    for path in files:
        yield from _xlsx_items(path) if kind == "xlsx" else _xml_items(path)


def read_version(snapshot_dir: Path) -> str | None:
    """The workbook's modification day, or the root ``date_create`` of the first XML."""
    kind, files = locate(snapshot_dir)
    if kind == "xlsx":
        with Workbook(files[0], XlsxLimits()) as book:
            return book.modified
    found = _check_roots(files)[0].get("date_create")
    return found if found and _VERSION.fullmatch(found) else None
