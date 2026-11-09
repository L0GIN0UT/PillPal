"""ESKLP importer skeleton (milestone 4.3). The real parser lands in 4.4b.

ESKLP has no published license text (docs/research/ru-sources.md, owner decision D1), so the
importer refuses every operation unless ``CATALOG_IMPORTER_ESKLP_ENABLED=true``. Setting the flag is
the owner's act after the checklist in docs/phase4-plan.md (milestone 4.4b).
"""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

from catalog.importers.base import (
    ImporterDisabled,
    ImporterError,
    LicenseNote,
    Record,
    SnapshotManifest,
)

ESKLP_SOURCE = "esklp"


class EsklpImporter:
    source = ESKLP_SOURCE
    license = LicenseNote(
        name="Unified state catalog of medicines (ESKLP)",
        license="No license text published; enabled only by the owner",
        attribution="Data: ESKLP, Ministry of Health of Russia",
        url="https://esklp.egisz.rosminzdrav.ru/",
    )

    def __init__(self, enabled: bool = False) -> None:
        self._enabled = enabled

    def ensure_enabled(self) -> None:
        if not self._enabled:
            raise ImporterDisabled

    def fetch(self, dest: Path) -> SnapshotManifest:
        del dest
        self.ensure_enabled()
        raise ImporterError("not_implemented")

    def snapshot_version(self, snapshot_dir: Path) -> str | None:
        del snapshot_dir
        self.ensure_enabled()
        raise ImporterError("not_implemented")

    def parse(self, snapshot_dir: Path) -> Iterator[Record]:
        del snapshot_dir
        self.ensure_enabled()
        raise ImporterError("not_implemented")
