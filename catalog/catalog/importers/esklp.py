"""ESKLP importer (milestone 4.4b, owner decision D1).

ESKLP has no published license text (docs/research/ru-sources.md), so every operation refuses
unless ``CATALOG_IMPORTER_ESKLP_ENABLED=true``; setting the flag is the owner's act after the
checklist in docs/phase4-plan.md (4.4b). ``fetch`` downloads one file named by the operator
(``esklp_fetch.py``); ``parse`` reads a snapshot directory (``esklp_source.py``).

SMNN (INN + form + strength) become substances and compositions (``esklp_smnn.py``); each KLP
becomes a product of market ``ru`` with one package and its GTINs. ``klp.UUID`` is the product
and package key, ``smnn.UUID`` the composition key. The loader needs all substances, then all
compositions, then all products, so the snapshot is read twice: the first pass only collects the
SMNN rows and the barcodes each KLP claims.

Dropped rows are counted by reason in ``skipped`` (``import_runs.counts.parse_skipped``), never
listed. A barcode printed on more than one KLP is ambiguous and dropped from all of them.
"""

from __future__ import annotations

from collections import Counter
from collections.abc import Callable, Iterator
from datetime import UTC, datetime
from pathlib import Path

import httpx

from catalog.importers.base import (
    ImporterDataError,
    ImporterDisabled,
    LicenseNote,
    PackageRecord,
    ProductRecord,
    Record,
    SnapshotManifest,
)
from catalog.importers.esklp_fetch import MAX_DOWNLOAD_BYTES, fetch_snapshot
from catalog.importers.esklp_smnn import SmnnCatalog, canonical_uuid
from catalog.importers.esklp_source import KLP, SMNN, Row, iter_items, read_version
from catalog.importers.ru_common import (
    ESKLP_SOURCE,
    MARKET,
    clean_text,
    is_individual_entrepreneur,
    normalize_registration_number,
    parse_barcodes,
)

MAX_BRAND_CHARS = 200
MAX_COUNTRY_CHARS = 100
MAX_PACK_CHARS = 300
Claims = dict[str, str | None]


class EsklpImporter:
    source = ESKLP_SOURCE
    # A successful run makes the source's attribution visible in GET /v1/sources.
    enables_source_on_success = True
    withdraws_missing = True
    license = LicenseNote(
        name="Unified state catalog of medicines (ESKLP)",
        license="No license text published; enabled only by the owner",
        attribution="Data: ESKLP, Ministry of Health of Russia",
        url="https://esklp.egisz.rosminzdrav.ru/",
    )

    def __init__(
        self,
        enabled: bool = False,
        transport: httpx.BaseTransport | None = None,
        now: Callable[[], datetime] | None = None,
        url: str | None = None,
        expected_sha256: str | None = None,
        max_download_bytes: int = MAX_DOWNLOAD_BYTES,
        ru_ca_file: Path | None = None,
        ru_ca_sha256: str | None = None,
    ) -> None:
        self._enabled = enabled
        self._transport = transport
        self._now = now or (lambda: datetime.now(UTC))
        self._url = url
        self._expected_sha256 = expected_sha256
        self._max_download_bytes = max_download_bytes
        self._ru_ca_file = ru_ca_file  # the Russian Trusted Root CA (fetch.py), or certifi only
        self._ru_ca_sha256 = ru_ca_sha256  # optional pin of that file's single certificate
        self.skipped: Counter[str] = Counter()

    def ensure_enabled(self) -> None:
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
            extra_ca_file=self._ru_ca_file,
            extra_ca_sha256=self._ru_ca_sha256,
        )

    def snapshot_version(self, snapshot_dir: Path) -> str | None:
        self.ensure_enabled()
        return read_version(snapshot_dir)

    def parse(self, snapshot_dir: Path) -> Iterator[Record]:
        self.ensure_enabled()
        self.skipped = Counter()
        smnn = SmnnCatalog(self.skipped)
        claims = self._first_pass(snapshot_dir, smnn)
        yield from smnn.substances()
        yield from smnn.compositions()
        yield from self._products(snapshot_dir, smnn, claims)

    @staticmethod
    def _first_pass(snapshot_dir: Path, smnn: SmnnCatalog) -> Claims:
        """Collect SMNN rows and which KLP claims which GTIN (``None``: claimed twice)."""
        claims: Claims = {}
        seen: set[str] = set()
        references = 0
        for kind, row in iter_items(snapshot_dir):
            smnn.add(row)
            if kind != KLP:
                continue
            references += 1 if row.get("smnn_uuid") else 0
            key = canonical_uuid(row.get("klp_uuid"))
            # the same validity test as _product: an invalid row must not take a barcode
            if (
                key is None
                or key in seen
                or clean_text(row.get("trade_name"), MAX_BRAND_CHARS) is None
            ):
                continue
            seen.add(key)
            for gtin in parse_barcodes(row.get("barcode"), Counter()):
                claims[gtin] = key if claims.get(gtin, key) == key else None
        if references and smnn.empty:
            # trade items name SMNN rows but none was read: a sheet or element was not recognised
            raise ImporterDataError("missing_sheet")
        return claims

    def _products(
        self, snapshot_dir: Path, smnn: SmnnCatalog, claims: Claims
    ) -> Iterator[ProductRecord]:
        seen: set[str] = set()
        emitted = 0
        for kind, row in iter_items(snapshot_dir):
            if kind == SMNN:
                continue
            product = self._product(row, smnn, claims, seen)
            if product is not None:
                emitted += 1
                yield product
        if emitted == 0:
            raise ImporterDataError("empty_snapshot")

    def _manufacturer(self, row: Row) -> str | None:
        name = clean_text(row.get("manufacturer"), MAX_BRAND_CHARS)
        if name is not None and is_individual_entrepreneur(name):
            self.skipped["manufacturer_individual"] += 1  # a natural person: never stored
            return None
        return name

    def _product(
        self, row: Row, smnn: SmnnCatalog, claims: Claims, seen: set[str]
    ) -> ProductRecord | None:
        key = canonical_uuid(row.get("klp_uuid"))
        name = clean_text(row.get("trade_name"), MAX_BRAND_CHARS)
        if key is None or name is None:
            self.skipped["invalid_klp"] += 1
            return None
        if key in seen:
            self.skipped["duplicate_klp"] += 1
            return None
        seen.add(key)
        smnn_key = canonical_uuid(row.get("smnn_uuid"))
        composition = smnn.composition_of.get(smnn_key) if smnn_key else None
        if composition is None:
            self.skipped["klp_without_smnn"] += 1
        printed = parse_barcodes(row.get("barcode"), self.skipped)
        gtins = tuple(g for g in printed if claims.get(g) == key)
        if len(gtins) < len(printed):
            self.skipped["gtin_ambiguous"] += len(printed) - len(gtins)
        return ProductRecord(
            source_key=key,
            market=MARKET,
            brand_name=name,
            # The manufacturer's name as published (for an individual entrepreneur this is the
            # legal name); the address and any other column are never read.
            manufacturer=self._manufacturer(row),
            country=clean_text(row.get("country"), MAX_COUNTRY_CHARS),
            composition_key=composition,
            registration_number=normalize_registration_number(row.get("num_reg")),
            packages=(PackageRecord(source_key=key, description=_pack(row), gtins=gtins),),
        )


def _pack(row: Row) -> str | None:
    parts = [clean_text(row.get(f), MAX_PACK_CHARS) for f in ("pack_1", "pack_2")]
    return ", ".join(p for p in parts if p) or None
