"""Importer protocol, parsed record types and stable error codes (docs/phase4-plan.md "Importer
design"). ``parse`` is pure (no database, no network); fetching and loading are separate steps so
a run is reproducible from a snapshot directory alone.

Errors carry a stable ``code`` and nothing else: the text of a catalog record or a file path must
not travel into an exception message, a log line or a run row.
"""

from __future__ import annotations

import hashlib
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal
from pathlib import Path
from typing import Protocol

READ_CHUNK_BYTES = 1024 * 1024


class ImporterError(Exception):
    """An importer or loader failure identified by a stable code."""

    code = "importer_error"

    def __init__(self, code: str | None = None) -> None:
        if code is not None:
            self.code = code
        super().__init__(self.code)


class ImporterDisabled(ImporterError):
    """The source is gated by a flag that the owner has not set."""

    code = "importer_disabled"


class ImporterDataError(ImporterError):
    """A snapshot record violates the catalog contract."""

    code = "invalid_snapshot"


@dataclass(frozen=True)
class LicenseNote:
    """Terms of a source, mirrored in ``sources`` and ``catalog/LICENSES.md``."""

    name: str
    license: str
    attribution: str
    url: str


@dataclass(frozen=True)
class SnapshotManifest:
    """What ``fetch`` reports: enough to reproduce and attribute a snapshot."""

    source: str
    version: str | None
    sha256: str
    retrieved_at: datetime
    url: str | None = None


@dataclass(frozen=True)
class IngredientRecord:
    substance_key: str
    strength_value: Decimal | None = None
    strength_unit: str | None = None
    per_value: Decimal | None = None
    per_unit: str | None = None


@dataclass(frozen=True)
class SubstanceRecord:
    source_key: str
    market: str
    name_en: str | None = None
    name_ru: str | None = None
    # Extra synonyms; name_en / name_ru are added to substance_names by the loader.
    names: tuple[tuple[str, str], ...] = ()


@dataclass(frozen=True)
class CompositionRecord:
    source_key: str
    market: str
    form_code: str | None
    ingredients: tuple[IngredientRecord, ...]
    complete: bool = False
    form_name_en: str | None = None
    form_name_ru: str | None = None


@dataclass(frozen=True)
class PackageRecord:
    source_key: str
    description: str | None = None
    count: Decimal | None = None
    count_unit: str | None = None
    gtins: tuple[str, ...] = ()


@dataclass(frozen=True)
class ProductRecord:
    source_key: str
    market: str
    brand_name: str
    manufacturer: str | None = None
    country: str | None = None
    composition_key: str | None = None
    # Source of the linked composition; None means the product's own source. The link is made
    # only if that composition row exists (a later import re-links).
    composition_source: str | None = None
    # Further (source, key) candidates tried in order when the primary one does not exist, e.g.
    # the product's own source-local composition behind an RxNorm one.
    composition_alternatives: tuple[tuple[str, str], ...] = ()
    rx_status: str | None = None
    registration_number: str | None = None
    packages: tuple[PackageRecord, ...] = field(default_factory=tuple)


Record = SubstanceRecord | CompositionRecord | ProductRecord
# ``parse`` yields all substances, then all compositions, then all products: the loader writes
# them in batches as they arrive, and a later level refers to an earlier one only.
RECORD_LEVELS: tuple[type, ...] = (SubstanceRecord, CompositionRecord, ProductRecord)


class Importer(Protocol):
    source: str
    license: LicenseNote

    def ensure_enabled(self) -> None:
        """Raise ``ImporterDisabled`` when the source is gated and the gate is closed."""

    def fetch(self, dest: Path) -> SnapshotManifest:
        """Download a snapshot into ``dest`` (network). Verifies size caps and sha256."""

    def snapshot_version(self, snapshot_dir: Path) -> str | None:
        """The source's own version or date of a snapshot, for ``import_runs``."""

    def parse(self, snapshot_dir: Path) -> Iterator[Record]:
        """Pure: records of a snapshot directory, no database and no network.

        Lazy: records are produced as the file is read, so memory does not grow with the file.
        An importer may expose ``skipped: dict[str, int]`` (records it dropped, by reason code);
        the loader adds it to the run counts as ``parse_skipped``.
        """


def snapshot_sha256(snapshot_dir: Path) -> str:
    """sha256 over relative file names and contents, in sorted order: the snapshot's identity."""
    digest = hashlib.sha256()
    files = sorted(p for p in snapshot_dir.rglob("*") if p.is_file())
    for path in files:
        digest.update(path.relative_to(snapshot_dir).as_posix().encode("utf-8"))
        digest.update(b"\0")
        with path.open("rb") as handle:
            while chunk := handle.read(READ_CHUNK_BYTES):
                digest.update(chunk)
        digest.update(b"\0")
    return digest.hexdigest()
