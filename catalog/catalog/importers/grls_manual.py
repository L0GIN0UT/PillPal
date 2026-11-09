"""GRLS manual export importer (milestone 4.4b, owner decision D1).

GRLS (grls.rosminzdrav.ru) has no bulk dump or API, and the site terms of the Ministry forbid
commercial reuse (docs/research/ru-sources.md section 1). The only supported path is therefore
the one the plan fixes: the owner downloads the Excel export of a search by hand, saves it as
``.xlsx`` and passes it with ``--snapshot``. Hence:

- ``CATALOG_IMPORTER_GRLS_ENABLED=false`` by default; every operation refuses while it is off;
- no network code at all: ``fetch`` refuses (``fetch_not_supported``) and nothing is scraped;
- the importer creates **no product and no package**: it attaches the export's barcodes to the
  live ESKLP package of the same registration number (a documented exception to "no cross-source
  linking", ``ru_levels.load_package_links``), only when that number names exactly one package;
- it never withdraws anything (``withdraws_missing = False``): a manual export is partial by
  nature.

FORMAT STATUS: written from the description of the export (registration number, trade name,
barcode columns) and verified on a synthetic workbook only; the export of the portal may be a
legacy ``.xls``, which must be re-saved as ``.xlsx`` first (it is refused with
``unsupported_format``). Check the headers in the owner's smoke import.
"""

from __future__ import annotations

from collections import Counter
from collections.abc import Iterator
from pathlib import Path

from catalog.importers.base import (
    ImporterDataError,
    ImporterDisabled,
    ImporterError,
    LicenseNote,
    PackageLinkRecord,
    Record,
    SnapshotManifest,
)
from catalog.importers.ru_common import normalize_registration_number, parse_barcodes
from catalog.importers.tabular import cell, find_columns, fold_aliases
from catalog.importers.xlsx import Workbook, XlsxLimits

GRLS_SOURCE = "grls_manual"
REQUIRED = ("num_reg", "barcode")
HEADER_SCAN_ROWS = 5
ALIASES = fold_aliases(
    {
        "num_reg": ["Номер РУ", "Номер регистрационного удостоверения", "Рег. номер", "№ РУ"],
        "barcode": ["Штрих-код", "Штрихкод", "Штрих код", "Штрих-коды", "EAN", "GTIN"],
    }
)


class GrlsManualImporter:
    source = GRLS_SOURCE
    enables_source_on_success = True
    withdraws_missing = False
    license = LicenseNote(
        name="State register of medicines (manual monthly export)",
        license="Site terms forbid commercial reuse; manual export, gated like ESKLP",
        attribution="Data: GRLS, Ministry of Health of Russia",
        url="https://grls.rosminzdrav.ru/",
    )

    def __init__(self, enabled: bool = False) -> None:
        self._enabled = enabled
        self.skipped: Counter[str] = Counter()

    def ensure_enabled(self) -> None:
        if not self._enabled:
            raise ImporterDisabled

    def fetch(self, dest: Path) -> SnapshotManifest:
        del dest
        self.ensure_enabled()
        raise ImporterError("fetch_not_supported")  # manual export only, never scraped

    @staticmethod
    def _workbook(snapshot_dir: Path) -> Path:
        files = sorted(p for p in snapshot_dir.rglob("*") if p.is_file() and not p.is_symlink())
        books = [p for p in files if p.suffix.lower() == ".xlsx"]
        if any(p.suffix.lower() == ".xls" for p in files) and not books:
            raise ImporterError("unsupported_format")
        if len(books) > 1:
            raise ImporterError("snapshot_ambiguous")
        if not books:
            raise ImporterError("snapshot_not_found")
        return books[0]

    def snapshot_version(self, snapshot_dir: Path) -> str | None:
        self.ensure_enabled()
        with Workbook(self._workbook(snapshot_dir), XlsxLimits()) as book:
            return book.modified

    def parse(self, snapshot_dir: Path) -> Iterator[Record]:
        self.ensure_enabled()
        self.skipped = Counter()
        emitted = 0
        with Workbook(self._workbook(snapshot_dir), XlsxLimits()) as book:
            for name in book.sheet_names:
                rows = iter(book.rows(name))
                columns = _find_header(rows)
                if columns is None:
                    continue  # a notes sheet; the first sheet with the columns is the export
                for record in self._links(rows, columns):
                    emitted += 1
                    yield record
                break
            else:
                raise ImporterDataError("missing_columns")
        if emitted == 0:
            raise ImporterDataError("empty_snapshot")

    def _links(
        self, rows: Iterator[list[str | None]], columns: dict[str, int]
    ) -> Iterator[PackageLinkRecord]:
        for row in rows:
            number = normalize_registration_number(cell(row, columns, "num_reg"))
            if number is None:
                self.skipped["invalid_row"] += 1
                continue
            gtins = parse_barcodes(cell(row, columns, "barcode"), self.skipped)
            if not gtins:
                self.skipped["no_barcode"] += 1
                continue
            yield PackageLinkRecord(registration_number=number, gtins=gtins)


def _find_header(rows: Iterator[list[str | None]]) -> dict[str, int] | None:
    for position, row in enumerate(rows):
        columns = find_columns(row, ALIASES)
        if all(field in columns for field in REQUIRED):
            return columns
        if position + 1 >= HEADER_SCAN_ROWS:
            break
    return None
