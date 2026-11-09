"""Builds small, format-faithful .xlsx workbooks for the RU importer tests (no spreadsheet
library: the importers read the package with the standard library, so the tests write it the
same way). Layout follows ECMA-376: [Content_Types].xml, xl/workbook.xml with its relationships,
xl/sharedStrings.xml and one worksheet part per sheet."""

from __future__ import annotations

import zipfile
from collections.abc import Mapping, Sequence
from pathlib import Path
from xml.sax.saxutils import escape

MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKG_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
FIXED_TIME = (2026, 10, 1, 0, 0, 0)

Cell = str | int | float | None
Rows = Sequence[Sequence[Cell]]


def _column(index: int) -> str:
    name = ""
    number = index + 1
    while number:
        number, rest = divmod(number - 1, 26)
        name = chr(ord("A") + rest) + name
    return name


def _cell(ref: str, value: str | int | float, strings: list[str], inline: bool) -> str:
    if not isinstance(value, str):
        return f'<c r="{ref}"><v>{value}</v></c>'
    if inline:
        return f'<c r="{ref}" t="inlineStr"><is><t>{escape(value)}</t></is></c>'
    if value not in strings:
        strings.append(value)
    return f'<c r="{ref}" t="s"><v>{strings.index(value)}</v></c>'


def _sheet_xml(rows: Rows, strings: list[str], inline: bool) -> str:
    out = [f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="{MAIN_NS}">']
    out.append("<sheetData>")
    for number, row in enumerate(rows, start=1):
        cells = [
            _cell(f"{_column(i)}{number}", v, strings, inline)
            for i, v in enumerate(row)
            if v is not None
        ]
        out.append(f'<row r="{number}">{"".join(cells)}</row>')
    out.append("</sheetData></worksheet>")
    return "".join(out)


def _package_parts(names: list[str]) -> dict[str, bytes]:
    book = "".join(
        f'<sheet name="{escape(n)}" sheetId="{i}" r:id="rId{i}"/>' for i, n in enumerate(names, 1)
    )
    rels = "".join(
        f'<Relationship Id="rId{i}" Type="{REL_NS}/worksheet" Target="worksheets/sheet{i}.xml"/>'
        for i in range(1, len(names) + 1)
    )
    return {
        "[Content_Types].xml": (
            b'<?xml version="1.0" encoding="UTF-8"?><Types xmlns='
            b'"http://schemas.openxmlformats.org/package/2006/content-types">'
            b'<Default Extension="xml" ContentType="application/xml"/></Types>'
        ),
        "xl/workbook.xml": (
            f'<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="{MAIN_NS}" '
            f'xmlns:r="{REL_NS}"><sheets>{book}</sheets></workbook>'
        ).encode(),
        "xl/_rels/workbook.xml.rels": (
            f'<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="{PKG_REL_NS}">'
            f"{rels}</Relationships>"
        ).encode(),
    }


def build_xlsx(
    path: Path,
    sheets: Mapping[str, Rows],
    *,
    inline_strings: bool = False,
    modified: str | None = "2026-10-01T00:00:00Z",
    extra_parts: Mapping[str, bytes] | None = None,
) -> Path:
    strings: list[str] = []
    names = list(sheets)
    parts = _package_parts(names)
    for number, name in enumerate(names, start=1):
        xml = _sheet_xml(sheets[name], strings, inline_strings)
        parts[f"xl/worksheets/sheet{number}.xml"] = xml.encode("utf-8")
    if strings:
        items = "".join(f"<si><t>{escape(s)}</t></si>" for s in strings)
        parts["xl/sharedStrings.xml"] = (
            f'<?xml version="1.0" encoding="UTF-8"?><sst xmlns="{MAIN_NS}" '
            f'count="{len(strings)}" uniqueCount="{len(strings)}">{items}</sst>'
        ).encode()
    if modified:
        parts["docProps/core.xml"] = (
            '<?xml version="1.0" encoding="UTF-8"?><cp:coreProperties xmlns:cp='
            '"http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
            'xmlns:dcterms="http://purl.org/dc/terms/" '
            'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
            f'<dcterms:modified xsi:type="dcterms:W3CDTF">{modified}</dcterms:modified>'
            "</cp:coreProperties>"
        ).encode()
    parts.update(extra_parts or {})
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in parts.items():
            info = zipfile.ZipInfo(name, FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
    return path
