"""EMA importer (milestone 4.8): centrally authorised human medicines of the EU (market ``eu``).

EMA publishes one workbook ("Medicines output: European public assessment reports") with a row per
medicine: name, active substance(s), product number, authorisation status and the marketing
authorisation holder (MAH). It carries no strength, no dosage form and no pack, so:

- a **composition is never complete**: it lists the active substances only (``form_code`` is
  ``None``, no strengths) and feeds the overlap hint, never "same composition" (ADR 0012 section 1);
  a product with several substances gets one incomplete composition of all of them;
- substances are source-local, keyed by the folded name (``name:<name>``, English, as in the
  openFDA importer); the list in the cell is split on ``,`` ``;`` and `` / `` (a name that itself
  contains such a separator would be split, which can only add a false overlap hint);
- the product key is the EMA product number, the manufacturer is the MAH (EU law requires a
  legal entity established in the Union, so the individual-entrepreneur rule of the RU sources is
  not applied), there is no registration number, package or GTIN;
- only human medicines with status ``Authorised`` are kept; withdrawn, suspended and refused ones
  are counted and, being absent, are withdrawn from the catalog by the next run.

FORMAT STATUS: synthetic only. The header wording (``ALIASES``), the title rows above the header
and the status values are written from memory of the public file; check them in the owner's smoke
import (catalog/README.md, "EMA (4.8)"). The workbook is read by ``xlsx.py`` under its limits,
tightened here to EMA's real size.
"""

from __future__ import annotations

import re
from collections import Counter
from collections.abc import Callable, Iterator
from datetime import UTC, datetime
from pathlib import Path

import httpx

from catalog.importers.base import (
    CompositionRecord,
    ImporterDataError,
    ImporterError,
    IngredientRecord,
    LicenseNote,
    ProductRecord,
    Record,
    SnapshotManifest,
    SubstanceRecord,
)
from catalog.importers.ema_fetch import DEFAULT_URL, MAX_DOWNLOAD_BYTES, fetch_snapshot
from catalog.importers.ru_common import clean_text, name_key
from catalog.importers.tabular import cell, find_columns, fold_aliases
from catalog.importers.xlsx import Workbook, XlsxLimits

EMA_SOURCE = "ema"
MARKET = "eu"
MAX_NAME_CHARS = 200
MAX_NUMBER_CHARS = 64
MAX_SUBSTANCES = 20
MAX_ROWS = 200_000  # the real list has a few tens of thousands of rows
MAX_COLUMNS = 80
HEADER_SCAN_ROWS = 30
AUTHORISED = "authorised"
HUMAN = "human"
REQUIRED = ("name", "substance", "number", "status")
ALIASES = fold_aliases(
    {
        "category": ["Category"],
        "name": ["Medicine name", "Name of medicine"],
        "substance": ["Active substance", "Active substances"],
        "number": ["Product number", "EMA product number"],
        "status": ["Authorisation status", "Medicine status", "Status"],
        "holder": [
            "Marketing authorisation holder/company name",
            "Marketing authorisation holder",
            "MAH",
        ],
    }
)
_SEPARATORS = re.compile(r"\s*(?:[,;]|\s/\s)\s*")


def substance_key(name: str) -> str:
    return f"name:{name_key(name)}"


def composition_key(names: list[str]) -> str:
    return "substances:" + "|".join(sorted(name_key(n) for n in names))


def _substances(raw: str | None) -> list[str]:
    """Distinct substance names of a cell (by folded name, first spelling wins)."""
    found: dict[str, str] = {}
    for part in _SEPARATORS.split(raw or ""):
        name = clean_text(part, MAX_NAME_CHARS)
        if name is not None:
            found.setdefault(name_key(name), name)
    return list(found.values())


def _header(rows: Iterator[list[str | None]]) -> dict[str, int]:
    for position, row in enumerate(rows):
        columns = find_columns(row, ALIASES)
        if all(field in columns for field in REQUIRED):
            return columns
        if position + 1 >= HEADER_SCAN_ROWS:
            break
    raise ImporterDataError("missing_columns")


def find_workbook(snapshot_dir: Path) -> Path:
    books = sorted(
        p
        for p in snapshot_dir.rglob("*")
        if p.is_file() and not p.is_symlink() and p.suffix.lower() == ".xlsx"
    )
    if len(books) > 1:
        raise ImporterError("snapshot_ambiguous")
    if not books:
        raise ImporterError("snapshot_not_found")
    return books[0]


class EmaImporter:
    source = EMA_SOURCE
    # The file lists every authorised medicine, so a medicine missing from it is gone.
    withdraws_missing = True
    # A successful run makes the attribution visible in GET /v1/sources.
    enables_source_on_success = True
    license = LicenseNote(
        name="EMA medicines data (EPAR report)",
        license="Reuse with acknowledgement of the source (EMA legal notice); not legally reviewed",
        attribution="Product data: European Medicines Agency",
        url="https://www.ema.europa.eu/en/medicines/download-medicine-data",
    )

    def __init__(
        self,
        transport: httpx.BaseTransport | None = None,
        now: Callable[[], datetime] | None = None,
        url: str | None = None,
        expected_sha256: str | None = None,
        max_download_bytes: int = MAX_DOWNLOAD_BYTES,
        max_rows: int = MAX_ROWS,
    ) -> None:
        self._transport = transport
        self._now = now or (lambda: datetime.now(UTC))
        self._url = url or DEFAULT_URL
        self._expected_sha256 = expected_sha256
        self._max_download_bytes = max_download_bytes
        self._limits = XlsxLimits(max_rows=max_rows, max_columns=MAX_COLUMNS)
        self.skipped: Counter[str] = Counter()

    def ensure_enabled(self) -> None:
        """EMA data is public and reusable with attribution: there is no gate."""

    def fetch(self, dest: Path) -> SnapshotManifest:
        return fetch_snapshot(
            dest,
            transport=self._transport,
            retrieved_at=self._now(),
            url=self._url,
            expected_sha256=self._expected_sha256,
            max_bytes=self._max_download_bytes,
            validate=self._read_through,
        )

    def _read_through(self, snapshot_dir: Path) -> None:
        if sum(1 for _ in self._products(snapshot_dir, Counter())) == 0:
            raise ImporterDataError("empty_snapshot")

    def snapshot_version(self, snapshot_dir: Path) -> str | None:
        with Workbook(find_workbook(snapshot_dir), self._limits) as book:
            return book.modified

    def parse(self, snapshot_dir: Path) -> Iterator[Record]:
        self.skipped = Counter()
        products = list(self._products(snapshot_dir, self.skipped))
        if not products:
            raise ImporterDataError("empty_snapshot")
        substances: dict[str, str] = {}
        compositions: dict[str, list[str]] = {}
        for _, names in products:
            compositions.setdefault(composition_key(names), names)
            for name in names:
                substances.setdefault(substance_key(name), name)
        for key in sorted(substances):
            yield SubstanceRecord(source_key=key, market=MARKET, name_en=substances[key])
        for key, names in sorted(compositions.items()):
            ordered = sorted({substance_key(n) for n in names})
            yield CompositionRecord(
                source_key=key,
                market=MARKET,
                form_code=None,
                ingredients=tuple(IngredientRecord(substance_key=k) for k in ordered),
                complete=False,  # EMA prints neither form nor strength: never complete
            )
        for product, names in products:
            yield ProductRecord(
                source_key=product.source_key,
                market=MARKET,
                brand_name=product.brand_name,
                manufacturer=product.manufacturer,
                composition_key=composition_key(names),
            )

    def _products(
        self, snapshot_dir: Path, skipped: Counter[str]
    ) -> Iterator[tuple[ProductRecord, list[str]]]:
        seen: set[str] = set()
        with Workbook(find_workbook(snapshot_dir), self._limits) as book:
            for name in book.sheet_names:
                rows = iter(book.rows(name))
                try:
                    columns = _header(rows)
                except ImporterDataError:
                    continue  # a notes sheet; the file as a whole is checked below
                for row in rows:
                    found = _product(row, columns, seen, skipped)
                    if found is not None:
                        yield found
                return
        raise ImporterDataError("missing_columns")


def _product(
    row: list[str | None], columns: dict[str, int], seen: set[str], skipped: Counter[str]
) -> tuple[ProductRecord, list[str]] | None:
    if not any(row):
        return None
    # Fail closed: an empty category or status cell is never "human" / "authorised". Only a file
    # without a category column at all is read as human (the column is optional).
    category = (cell(row, columns, "category") or "").strip().casefold()
    if "category" in columns and category != HUMAN:
        skipped["not_human"] += 1
        return None
    status = (cell(row, columns, "status") or "").strip().casefold()
    if status != AUTHORISED:
        skipped["not_authorised"] += 1
        return None
    key = clean_text(cell(row, columns, "number"), MAX_NUMBER_CHARS)
    brand = clean_text(cell(row, columns, "name"), MAX_NAME_CHARS)
    names = _substances(cell(row, columns, "substance"))
    if key is None or brand is None or not names or len(names) > MAX_SUBSTANCES:
        skipped["invalid_product"] += 1
        return None
    if key in seen:
        skipped["duplicate_product"] += 1
        return None
    seen.add(key)
    holder = clean_text(cell(row, columns, "holder"), MAX_NAME_CHARS)
    product = ProductRecord(source_key=key, market=MARKET, brand_name=brand, manufacturer=holder)
    return product, names
