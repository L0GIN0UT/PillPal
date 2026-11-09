"""Roszdravnadzor open data: recalled and withdrawn series -> ``recall_flags`` (milestone 4.4b).

The set is published with an explicit open license (docs/research/ru-sources.md section 4: free,
commercial use allowed, a link to the source required). It holds no catalog, only decisions about
series of a registration certificate, so this importer creates no product: the card joins the
flags to ESKLP products through ``products.registration_number``.

The input is one CSV file the operator names (``--url``) or supplies; no page is scraped. The
file is read in a streaming way with a size cap, a row cap and csv's field limit. Of every
decision only the registration number, the series, a reason **code** and the date are kept; the
free text of the decision never enters the catalog.

FORMAT STATUS: columns are matched by header wording (``ALIASES``) and were written from the
open-data description, not from a live file; check them in the owner's smoke import.
"""

from __future__ import annotations

import codecs
import csv
import re
from collections import Counter
from collections.abc import Callable, Iterator
from datetime import UTC, datetime
from pathlib import Path

import httpx

from catalog.importers.base import (
    ImporterDataError,
    ImporterError,
    LicenseNote,
    RecallRecord,
    Record,
    SnapshotManifest,
)
from catalog.importers.ru_common import clean_text, normalize_registration_number
from catalog.importers.ru_roszdravnadzor_fetch import MAX_DOWNLOAD_BYTES, fetch_snapshot
from catalog.importers.tabular import find_columns, fold_aliases, require_columns

SOURCE = "ru_roszdravnadzor"
MAX_CSV_BYTES = 256 * 1024 * 1024
MAX_ROWS = 2_000_000
MAX_SERIES_CHARS = 64
HEADER_SCAN_ROWS = 5
ENCODING_SNIFF_BYTES = 64 * 1024
REQUIRED = ("num_reg", "series")
ALIASES = fold_aliases(
    {
        "num_reg": [
            "Номер РУ",
            "Регистрационный номер",
            "Номер регистрационного удостоверения",
            "num_reg",
        ],
        "series": ["Серия", "Серия препарата", "series"],
        "reason": ["Причина", "Решение", "Основание", "Вид решения", "reason"],
        "date": ["Дата", "Дата решения", "Дата письма", "date"],
    }
)
# Checked in this order: the first stem found in the decision text names the code.
REASON_CODES = (
    ("фальсиф", "counterfeit"),
    ("забрак", "substandard"),
    ("недоброкачествен", "substandard"),
    ("изъят", "withdrawn"),
    ("приостанов", "suspended"),
)
OTHER_REASON = "other"
_DOTTED = re.compile(r"(\d{2})\.(\d{2})\.(\d{4})", re.ASCII)
_ISO = re.compile(r"(\d{4})-(\d{2})-(\d{2})", re.ASCII)


def reason_code_of(text: str) -> str:
    folded = text.casefold().replace("ё", "е")
    return next((code for stem, code in REASON_CODES if stem in folded), OTHER_REASON)


def _date_of(text: str | None) -> datetime | None:
    if not text:
        return None
    value = text.strip()
    if found := _DOTTED.match(value):
        day, month, year = (int(g) for g in found.groups())
    elif found := _ISO.match(value):
        year, month, day = (int(g) for g in found.groups())
    else:
        raise ValueError
    return datetime(year, month, day, tzinfo=UTC)


def _encoding_of(path: Path) -> str:
    """UTF-8 (with or without BOM) when the head of the file decodes as such, else cp1251."""
    with path.open("rb") as handle:
        head = handle.read(ENCODING_SNIFF_BYTES)
    try:
        codecs.getincrementaldecoder("utf-8-sig")().decode(head, final=False)
    except UnicodeDecodeError:
        return "cp1251"
    return "utf-8-sig"


def _delimiter_of(first_line: str) -> str:
    return max(";\t,", key=first_line.count)


def find_csv(snapshot_dir: Path) -> Path:
    files = sorted(p for p in snapshot_dir.rglob("*") if p.is_file() and p.suffix.lower() == ".csv")
    if len(files) > 1:
        raise ImporterError("snapshot_ambiguous")
    if not files:
        raise ImporterError("snapshot_not_found")
    return files[0]


def read_recalls(
    snapshot_dir: Path, skipped: Counter[str], *, max_bytes: int, max_rows: int
) -> Iterator[RecallRecord]:
    path = find_csv(snapshot_dir)
    if path.stat().st_size > max_bytes:
        raise ImporterError("snapshot_too_large")
    emitted = 0
    try:
        with path.open(encoding=_encoding_of(path), newline="") as handle:
            first = handle.readline()
            handle.seek(0)
            rows = csv.reader(handle, delimiter=_delimiter_of(first))
            columns = _header(rows)
            for number, row in enumerate(rows, start=1):
                if number > max_rows:
                    raise ImporterDataError("snapshot_too_large")
                record = _record(row, columns, skipped)
                if record is not None:
                    emitted += 1
                    yield record
    except (csv.Error, UnicodeDecodeError):
        raise ImporterDataError("invalid_snapshot") from None
    if emitted == 0:
        raise ImporterDataError("empty_snapshot")


def _header(rows: Iterator[list[str]]) -> dict[str, int]:
    for position, row in enumerate(rows):
        columns = find_columns(row, ALIASES)
        if all(field in columns for field in REQUIRED):
            return columns
        if position + 1 >= HEADER_SCAN_ROWS:
            break
    require_columns({}, REQUIRED)  # raises missing_columns
    return {}


def _record(row: list[str], columns: dict[str, int], skipped: Counter[str]) -> RecallRecord | None:
    def value(field: str) -> str | None:
        position = columns.get(field)
        return row[position] if position is not None and position < len(row) else None

    number = normalize_registration_number(value("num_reg"))
    series = clean_text(value("series"), MAX_SERIES_CHARS)
    if number is None or series is None:
        skipped["invalid_row"] += 1
        return None
    try:
        published = _date_of(value("date"))
    except ValueError:
        skipped["invalid_date"] += 1
        published = None
    return RecallRecord(number, series, reason_code_of(value("reason") or ""), published)


class RoszdravnadzorImporter:
    source = SOURCE
    enables_source_on_success = True
    # The list is cumulative public data and the loader never deletes flags.
    withdraws_missing = False
    license = LicenseNote(
        name="Roszdravnadzor open data",
        license="Open license: free, perpetual, commercial use, source link required",
        attribution="Data: Roszdravnadzor (open data)",
        url="https://roszdravnadzor.gov.ru/opendata",
    )

    def __init__(
        self,
        transport: httpx.BaseTransport | None = None,
        now: Callable[[], datetime] | None = None,
        url: str | None = None,
        expected_sha256: str | None = None,
        max_download_bytes: int = MAX_DOWNLOAD_BYTES,
        max_csv_bytes: int = MAX_CSV_BYTES,
        max_rows: int = MAX_ROWS,
    ) -> None:
        self._transport = transport
        self._now = now or (lambda: datetime.now(UTC))
        self._url = url
        self._expected_sha256 = expected_sha256
        self._max_download_bytes = max_download_bytes
        self._max_csv_bytes = max_csv_bytes
        self._max_rows = max_rows
        self.skipped: Counter[str] = Counter()

    def ensure_enabled(self) -> None:
        return None

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
        for _ in read_recalls(
            snapshot_dir, Counter(), max_bytes=self._max_csv_bytes, max_rows=self._max_rows
        ):
            pass

    def snapshot_version(self, snapshot_dir: Path) -> str | None:
        return None  # the CSV carries no version of its own

    def parse(self, snapshot_dir: Path) -> Iterator[Record]:
        self.skipped = Counter()
        yield from read_recalls(
            snapshot_dir, self.skipped, max_bytes=self._max_csv_bytes, max_rows=self._max_rows
        )
