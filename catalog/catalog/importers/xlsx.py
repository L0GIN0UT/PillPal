"""A small read-only reader of .xlsx workbooks (ECMA-376 SpreadsheetML), standard library only.

The workbook is an untrusted file (an operator-supplied export or a download), so reading it is
bounded on every axis before any value reaches an importer: members and their ratio are checked
from the zip directory, the bytes actually decompressed are counted, and sheet, row, column,
cell-length and shared-string counts have caps (``XlsxLimits``). Nothing is extracted to disk and
no formula is evaluated. A violation raises ``ImporterDataError`` with ``xlsx_too_large``; a
broken, truncated or hostile package raises it with ``xlsx_invalid``. Values are returned as text.
"""

from __future__ import annotations

import posixpath
import re
import stat
import zipfile
from collections.abc import Iterator
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path
from types import TracebackType
from typing import Any
from xml.etree import ElementTree as ET

from catalog.importers.base import ImporterDataError
from catalog.importers.safe_xml import GuardedStream, iterparse, local_name

INVALID = "xlsx_invalid"
TOO_LARGE = "xlsx_too_large"
WORKBOOK_PART = "xl/workbook.xml"
RELS_PART = "xl/_rels/workbook.xml.rels"
SHARED_STRINGS_PART = "xl/sharedStrings.xml"
CORE_PART = "docProps/core.xml"
RATIO_FLOOR_BYTES = 1024 * 1024  # tiny parts may compress well without being a bomb
_CELL_REF = re.compile(r"([A-Z]{1,4})(\d{1,9})", re.ASCII)
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}", re.ASCII)
_PARSE_ERRORS = (ET.ParseError, zipfile.BadZipFile, KeyError, ValueError, OSError, RuntimeError)
_MAX_PARTS = 2000

Row = list[str | None]


@dataclass(frozen=True)
class XlsxLimits:
    max_part_bytes: int = 1024**3
    max_ratio: int = 200
    max_sheets: int = 20
    max_rows: int = 2_000_000
    max_columns: int = 200
    max_cell_chars: int = 32_767  # the limit Excel itself enforces
    max_shared_strings: int = 5_000_000
    # Decompressed bytes read from the whole workbook, all parts together.
    max_total_bytes: int = 4 * 1024**3


def _column_index(letters: str) -> int:
    index = 0
    for ch in letters:
        index = index * 26 + ord(ch) - ord("A") + 1
    return index - 1


MAX_PLAIN_EXPONENT = 30


def _number_text(raw: str) -> str:
    """Excel prints large numbers in exponent form (``4.6E12``); barcodes need plain digits."""
    if "e" not in raw.lower():
        return raw
    try:
        value = Decimal(raw)
    except InvalidOperation:
        return raw
    if not value.is_finite() or abs(value.adjusted()) > MAX_PLAIN_EXPONENT:
        return raw  # never expand an absurd exponent into a giant string
    if value == value.to_integral():
        return format(value.to_integral_value(), "f")
    return format(value, "f")


def _text_of(element: ET.Element) -> str:
    """Visible text of a string item: direct runs and rich-text runs, not phonetic hints."""
    parts: list[str] = []
    for child in element:
        name = local_name(child.tag)
        if name == "t":
            parts.append(child.text or "")
        elif name == "r":
            parts.extend((t.text or "") for t in child if local_name(t.tag) == "t")
    return "".join(parts)


class Workbook:
    """Context manager over one workbook file; ``rows(sheet)`` streams a sheet."""

    def __init__(self, path: Path, limits: XlsxLimits | None = None) -> None:
        self._path = path
        self._limits = limits or XlsxLimits()
        self._zip: zipfile.ZipFile | None = None
        self._sheets: dict[str, str] = {}
        self._strings: list[str] | None = None
        self._read_bytes = 0

    def __enter__(self) -> Workbook:
        try:
            self._zip = zipfile.ZipFile(self._path)
            self._check_directory(self._zip)
            self._sheets = self._read_sheets()
        except ImporterDataError:
            self.close()
            raise
        except _PARSE_ERRORS:
            self.close()
            raise ImporterDataError(INVALID) from None
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self.close()

    def close(self) -> None:
        if self._zip is not None:
            self._zip.close()
            self._zip = None

    @property
    def sheet_names(self) -> list[str]:
        return list(self._sheets)

    @property
    def modified(self) -> str | None:
        """``YYYY-MM-DD`` of the workbook's last modification, the best version a file has."""
        try:
            with self._open(CORE_PART) as stream:
                for _, element in iterparse(stream, events=("end",)):
                    if local_name(element.tag) == "modified" and element.text:
                        day = element.text.strip()[:10]
                        return day if _DATE.fullmatch(day) else None
        except KeyError:
            return None
        except _PARSE_ERRORS:
            raise ImporterDataError(INVALID) from None
        return None

    def _check_directory(self, archive: zipfile.ZipFile) -> None:
        members = archive.infolist()
        if len(members) > _MAX_PARTS:
            raise ImporterDataError(TOO_LARGE)
        for info in members:
            if stat.S_ISLNK(info.external_attr >> 16) or info.flag_bits & 0x1:
                raise ImporterDataError(INVALID)  # symbolic links and encrypted members
        if WORKBOOK_PART not in archive.namelist():
            raise ImporterDataError(INVALID)

    def _open(self, part: str) -> GuardedStream:
        if self._zip is None:
            raise ImporterDataError(INVALID)
        info = self._zip.getinfo(part)  # KeyError for a missing part: callers map it
        limits = self._limits
        if info.file_size > limits.max_part_bytes:
            raise ImporterDataError(TOO_LARGE)
        if (
            info.file_size > RATIO_FLOOR_BYTES
            and info.file_size > info.compress_size * limits.max_ratio
        ):
            raise ImporterDataError(TOO_LARGE)
        return GuardedStream(
            self._zip.open(info), limits.max_part_bytes, TOO_LARGE, INVALID, self._spend
        )

    def _spend(self, size: int) -> None:
        self._read_bytes += size
        if self._read_bytes > self._limits.max_total_bytes:
            raise ImporterDataError(TOO_LARGE)

    def _read_sheets(self) -> dict[str, str]:
        targets: dict[str, str] = {}
        with self._open(RELS_PART) as rels:
            for _, element in iterparse(rels, events=("end",)):
                if local_name(element.tag) == "Relationship":
                    if len(targets) >= _MAX_PARTS:
                        raise ImporterDataError(TOO_LARGE)
                    target = element.get("Target", "")
                    rooted = target.lstrip("/") if target.startswith("/") else f"xl/{target}"
                    targets[element.get("Id", "")] = posixpath.normpath(rooted)
        sheets: dict[str, str] = {}
        with self._open(WORKBOOK_PART) as book:
            for _, element in iterparse(book, events=("end",)):
                if local_name(element.tag) != "sheet":
                    continue
                rid = next((v for k, v in element.attrib.items() if local_name(k) == "id"), "")
                name, part = element.get("name"), targets.get(rid)
                if not name or part is None or part.startswith(".."):
                    raise ImporterDataError(INVALID)
                sheets[name] = part
                if len(sheets) > self._limits.max_sheets:
                    raise ImporterDataError(TOO_LARGE)
        return sheets

    def _shared_strings(self) -> list[str]:
        if self._strings is None:
            strings: list[str] = []
            try:
                stream = self._open(SHARED_STRINGS_PART)
            except KeyError:
                self._strings = strings
                return strings
            with stream:
                root: ET.Element | None = None
                depth = 0
                for event, element in iterparse(stream, events=("start", "end")):
                    if event == "start":
                        depth += 1
                        root = element if root is None else root
                        continue
                    depth -= 1
                    if depth != 1 or root is None:
                        continue
                    if local_name(element.tag) == "si":
                        if len(strings) >= self._limits.max_shared_strings:
                            raise ImporterDataError(TOO_LARGE)
                        text = _text_of(element)
                        if len(text) > self._limits.max_cell_chars:
                            raise ImporterDataError(TOO_LARGE)
                        strings.append(text)
                    root.remove(element)  # nothing that has ended is kept
            self._strings = strings
        return self._strings

    def rows(self, sheet: str) -> Iterator[Row]:
        """Rows of ``sheet`` in file order, cells by column position (gaps are ``None``)."""
        try:
            part = self._sheets[sheet]
            strings = self._shared_strings()
            with self._open(part) as stream:
                yield from self._iterate(stream, strings)
        except ImporterDataError:
            raise
        except _PARSE_ERRORS:
            raise ImporterDataError(INVALID) from None

    def _iterate(self, stream: Any, strings: list[str]) -> Iterator[Row]:
        limits = self._limits
        root: ET.Element | None = None
        sheet_data: ET.Element | None = None
        row_element: ET.Element | None = None
        row: Row = []
        rows = 0
        depth = 0
        # Depths: worksheet 1, sheetData 2, row 3, cell 4. Whatever ends is dropped from its
        # parent at once, so junk siblings cannot pile up in memory.
        for event, element in iterparse(stream, events=("start", "end")):
            name = local_name(element.tag)
            if event == "start":
                depth += 1
                if root is None:
                    root = element
                elif name == "sheetData" and depth == 2:
                    sheet_data = element
                elif name == "row" and depth == 3:
                    rows += 1
                    if rows > limits.max_rows:
                        raise ImporterDataError(TOO_LARGE)
                    row, row_element = [], element
                continue
            depth -= 1
            if depth == 1 and name != "sheetData" and root is not None:
                root.remove(element)
            elif depth == 2 and name == "row":
                yield row
                if sheet_data is not None:
                    sheet_data.clear()
            elif depth == 3 and row_element is not None:
                if name == "c":
                    self._add_cell(row, element, strings)
                row_element.remove(element)

    def _add_cell(self, row: Row, cell: ET.Element, strings: list[str]) -> None:
        limits = self._limits
        found = _CELL_REF.fullmatch(cell.get("r", ""))
        index = _column_index(found.group(1)) if found else len(row)
        if index >= limits.max_columns:
            raise ImporterDataError(TOO_LARGE)
        value = self._value(cell, strings)
        if value is not None and len(value) > limits.max_cell_chars:
            raise ImporterDataError(TOO_LARGE)
        if index < len(row):
            raise ImporterDataError(INVALID)  # cells must be in column order
        row.extend([None] * (index - len(row)))
        row.append(value)

    @staticmethod
    def _value(cell: ET.Element, strings: list[str]) -> str | None:
        kind = cell.get("t", "n")
        if kind == "inlineStr":
            inline = next((c for c in cell if local_name(c.tag) == "is"), None)
            return None if inline is None else _text_of(inline)
        raw = next((c.text for c in cell if local_name(c.tag) == "v"), None)
        if raw is None or kind == "e":
            return None
        if kind == "s":
            position = int(raw)
            if not 0 <= position < len(strings):
                raise ImporterDataError(INVALID)
            return strings[position]
        return _number_text(raw) if kind == "n" else raw
