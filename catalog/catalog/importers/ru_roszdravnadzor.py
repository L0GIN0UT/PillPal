"""Roszdravnadzor open data: recalled and withdrawn series -> ``recall_flags`` (milestone 4.4b).

Recall series are compared exactly as printed (no case folding): a registration number is
normalized, a series is not.

The set is published with an explicit open license (docs/research/ru-sources.md section 4: free,
commercial use allowed, a link to the source required). It holds no catalog, only decisions about
series of a registration certificate, so this importer creates no product: the card joins the
flags to ESKLP products through ``products.registration_number``.

The input is one CSV file the operator names (``--url``) or supplies; no page is scraped. The
file is read in a streaming way with a size cap, a row cap and csv's field limit. Of every
decision only the registration number, the series, a reason **code** and the date are kept; the
trade name, producer, letter number and the wording of the decision never enter the catalog.

FORMAT STATUS: checked against the real "drugs_qualitycontrol" file (2026-11: cp1251, ``;``,
quoted, header ``trade_name;no_ru;dt_ru;series;producer;country;status;type;letter_number;
letter_date``, ~42 500 rows, newest first). Only rows whose ``status`` and ``type`` are on the
allow-lists below become flags (``outcome_of``), minus suspensions that a newer permission of the
same series in the file lifts; the rest are counted by reason. The loader keeps the newest
decision of a series (``ru_levels.py``).
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
    ImporterDisabled,
    ImporterError,
    LicenseNote,
    RecallRecord,
    Record,
    SnapshotManifest,
)
from catalog.importers.ru_common import clean_text, normalize_registration_number
from catalog.importers.ru_roszdravnadzor_fetch import MAX_DOWNLOAD_BYTES, fetch_snapshot
from catalog.importers.tabular import find_columns, fold_aliases, header_key, require_columns

SOURCE = "ru_roszdravnadzor"
MAX_CSV_BYTES = 256 * 1024 * 1024
MAX_ROWS = 2_000_000
MAX_COLUMNS = 200
MAX_SERIES_CHARS = 64
HEADER_SCAN_ROWS = 5
ENCODING_SNIFF_BYTES = 64 * 1024
REQUIRED = ("num_reg", "series", "status", "decision")
ALIASES = fold_aliases(
    {
        "num_reg": ["no_ru", "Номер РУ", "Регистрационный номер"],
        "series": ["series", "Серия"],
        "status": ["status", "Статус"],
        "decision": ["type", "Тип", "Вид решения"],
        "date": ["letter_date", "Дата письма"],
    }
)
# The file mixes negative decisions with permissions ("Разрешение реализации", "О снятии с
# посерийного контроля") that must never become flags. The status says what kind of product it
# is, the decision type what happened to the series. A row becomes a flag only when both are on
# these allow-lists (values compared folded with ``header_key``: case, ``ё``, spaces and
# punctuation ignored, so "_Изъятие" is "Изъятие"); anything else is counted and skipped,
# including values Roszdravnadzor may add later. "оригинальное ЛС" is a genuine (not falsified)
# product: most such letters recall or suspend it, so its code comes from the decision alone.
STATUS_CODES = {
    header_key(status): code
    for status, code in (
        ("недоброкачественное ЛС", "substandard"),
        ("фальсифицированное ЛС", "counterfeit"),
        ("незаконный оборот", "withdrawn"),
        ("незарегистрированное ЛС", "withdrawn"),
        ("оригинальное ЛС", "withdrawn"),
    )
}
# "сомнительное ЛС" is a suspicion under investigation, not a finding: it often ends in
# "Разрешение (серия)", and a flag is never deleted by a later import, so it is skipped. A
# confirmed counterfeit is published again with the status "фальсифицированное ЛС".
SUSPECTED_STATUS = header_key("сомнительное ЛС")
SUSPENSIONS = frozenset(
    header_key(t)
    for t in ("Приостановление", "Приостановление реализации", "Фальсификация приостановление")
)
NEGATIVE_DECISIONS = SUSPENSIONS | frozenset(
    header_key(t)
    for t in (
        "Отзыв",
        "Отзыв производителем",
        "Отзыв производителем партии",
        "Отзыв производителем (Ф/С)",
        "Отзыв деклараций о соответствии",
        "Брак производителя Россия",
        "Брак производителя (территория)",
        "Брак производителя (партия)",
        "Брак производителя (изъятие без уничтожения)",
        "Брак поставщика (подтвержден)",
        "Изъятие",
        "Изъятие незарегистрированного ЛС",
        "Изъятие по неподтвержденной декларации",
        "Прекращение обращения",
        "Фальсификация",
        "Фальсификация (изъятие по признакам)",
        "Фальсификация полное изъятие",
        "Контрафакт",
        "Незаконный ввоз",
    )
)
# Decisions that release a series again: a suspension of the same series dated before one of
# them (in the same file) is not a flag.
PERMISSIONS = frozenset(
    header_key(t)
    for t in (
        "Разрешение реализации",
        "О разрешении к реализации серии",
        "О снятии с посерийного контроля",
        "Разрешение (серия)",
        "Разрешение (партия)",
    )
)
SUSPENDED = "suspended"
_DOTTED = re.compile(r"(\d{2})\.(\d{2})\.(\d{4})", re.ASCII)
_ISO = re.compile(r"(\d{4})-(\d{2})-(\d{2})", re.ASCII)
Value = Callable[[str], str | None]
SeriesKey = tuple[str, str]


def outcome_of(status: str | None, decision: str | None) -> tuple[str | None, str | None]:
    """``(reason code, None)`` for a negative outcome, else ``(None, skip reason)``."""
    status_key = header_key(status or "")
    code = STATUS_CODES.get(status_key)
    if code is None:
        return None, "status_suspected" if status_key == SUSPECTED_STATUS else "status_unknown"
    decision_key = header_key(decision or "")
    if decision_key not in NEGATIVE_DECISIONS:
        return None, "decision_not_negative"
    return (SUSPENDED if decision_key in SUSPENSIONS else code), None


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
    files = sorted(
        p
        for p in snapshot_dir.rglob("*")
        if p.is_file() and not p.is_symlink() and p.suffix.lower() == ".csv"
    )
    if len(files) > 1:
        raise ImporterError("snapshot_ambiguous")
    if not files:
        raise ImporterError("snapshot_not_found")
    return files[0]


def read_recalls(
    snapshot_dir: Path, skipped: Counter[str], *, max_bytes: int, max_rows: int
) -> Iterator[RecallRecord]:
    """Two passes over the file: the first collects the newest permission of every series, the
    second emits the negative outcomes (a suspension older than a permission is dropped)."""
    path = find_csv(snapshot_dir)
    if path.stat().st_size > max_bytes:
        raise ImporterError("snapshot_too_large")
    emitted = 0
    try:
        released = _permissions(_rows(path, max_rows))
        for value in _rows(path, max_rows):
            record = _record(value, skipped, released)
            if record is not None:
                emitted += 1
                yield record
    except (csv.Error, UnicodeDecodeError):
        raise ImporterDataError("invalid_snapshot") from None
    if emitted == 0:
        raise ImporterDataError("empty_snapshot")


def _rows(path: Path, max_rows: int) -> Iterator[Value]:
    with path.open(encoding=_encoding_of(path), newline="") as handle:
        first = handle.readline(ENCODING_SNIFF_BYTES)
        handle.seek(0)
        rows = _bounded(csv.reader(handle, delimiter=_delimiter_of(first)))
        columns = _header(rows)
        for number, row in enumerate(rows, start=1):
            if number > max_rows:
                raise ImporterDataError("snapshot_too_large")
            yield _getter(row, columns)


def _getter(row: list[str], columns: dict[str, int]) -> Value:
    def value(field: str) -> str | None:
        position = columns.get(field)
        return row[position] if position is not None and position < len(row) else None

    return value


def _bounded(rows: Iterator[list[str]]) -> Iterator[list[str]]:
    for row in rows:
        if len(row) > MAX_COLUMNS:
            raise ImporterDataError("invalid_snapshot")
        yield row


def _header(rows: Iterator[list[str]]) -> dict[str, int]:
    for position, row in enumerate(rows):
        columns = find_columns(row, ALIASES)
        if all(field in columns for field in REQUIRED):
            return columns
        if position + 1 >= HEADER_SCAN_ROWS:
            break
    require_columns({}, REQUIRED)  # raises missing_columns
    return {}


def _series_key(value: Value) -> SeriesKey | None:
    number = normalize_registration_number(value("num_reg"))
    series = clean_text(value("series"), MAX_SERIES_CHARS)
    return None if number is None or series is None else (number, series)


def _permissions(rows: Iterator[Value]) -> dict[SeriesKey, datetime]:
    """The newest dated permission of every series (an undated one releases nothing)."""
    newest: dict[SeriesKey, datetime] = {}
    for value in rows:
        key = _series_key(value)
        if key is None or header_key(value("decision") or "") not in PERMISSIONS:
            continue
        try:
            date = _date_of(value("date"))
        except ValueError:
            continue
        if date is not None and (key not in newest or date > newest[key]):
            newest[key] = date
    return newest


def _record(
    value: Value, skipped: Counter[str], released: dict[SeriesKey, datetime]
) -> RecallRecord | None:
    key = _series_key(value)
    if key is None:
        skipped["invalid_row"] += 1
        return None
    code, skip = outcome_of(value("status"), value("decision"))
    if code is None:
        skipped[skip or "status_unknown"] += 1
        return None
    try:
        published = _date_of(value("date"))
    except ValueError:
        skipped["invalid_date"] += 1
        published = None
    permitted = released.get(key)
    if code == SUSPENDED and permitted is not None and (published is None or permitted > published):
        skipped["suspension_lifted"] += 1  # an undated suspension counts as the oldest
        return None
    return RecallRecord(key[0], key[1], code, published)


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
        enabled: bool = False,
        transport: httpx.BaseTransport | None = None,
        now: Callable[[], datetime] | None = None,
        url: str | None = None,
        expected_sha256: str | None = None,
        max_download_bytes: int = MAX_DOWNLOAD_BYTES,
        max_csv_bytes: int = MAX_CSV_BYTES,
        max_rows: int = MAX_ROWS,
    ) -> None:
        self._enabled = enabled
        self._transport = transport
        self._now = now or (lambda: datetime.now(UTC))
        self._url = url
        self._expected_sha256 = expected_sha256
        self._max_download_bytes = max_download_bytes
        self._max_csv_bytes = max_csv_bytes
        self._max_rows = max_rows
        self.skipped: Counter[str] = Counter()

    def ensure_enabled(self) -> None:
        # Recall flags attach to ESKLP products, so they follow the ESKLP flag (plan 4.4b).
        if not self._enabled:
            raise ImporterDisabled

    def fetch(self, dest: Path) -> SnapshotManifest:
        self.ensure_enabled()
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
        self.ensure_enabled()
        return None  # the CSV carries no version of its own

    def parse(self, snapshot_dir: Path) -> Iterator[Record]:
        self.ensure_enabled()
        self.skipped = Counter()
        yield from read_recalls(
            snapshot_dir, self.skipped, max_bytes=self._max_csv_bytes, max_rows=self._max_rows
        )
