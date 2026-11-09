"""A synthetic importer for development and tests: it reads ``data.json`` of a snapshot
directory (format of ``tests/fixtures/fixture/``). Names are invented ("Testamol"), GTINs are
made up with valid check digits (privacy rule 9). It exists to exercise the shared loader; it is
not a source of real data and the CLI refuses it in staging and prod."""

from __future__ import annotations

import json
from collections.abc import Iterator
from decimal import Decimal
from pathlib import Path
from typing import Any

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from catalog.importers.base import (
    CompositionRecord,
    ImporterDataError,
    ImporterError,
    IngredientRecord,
    LicenseNote,
    PackageRecord,
    ProductRecord,
    Record,
    SnapshotManifest,
    SubstanceRecord,
)

DATA_FILE = "data.json"
FIXTURE_SOURCE = "fixture"
FIXTURE_LICENSE = LicenseNote(
    name="Synthetic fixture data",
    license="Synthetic: no real products",
    attribution="Synthetic fixture data",
    url="https://pillpal.invalid/catalog/fixture",
)


def _decimal(value: Any) -> Decimal | None:
    return None if value is None else Decimal(str(value))


class FixtureImporter:
    withdraws_missing = True
    enables_source_on_success = False
    license = FIXTURE_LICENSE

    def __init__(self, source: str = FIXTURE_SOURCE) -> None:
        self.source = source

    def ensure_enabled(self) -> None:
        return None

    def fetch(self, dest: Path) -> SnapshotManifest:
        del dest
        raise ImporterError("fetch_not_supported")

    def _read(self, snapshot_dir: Path) -> dict[str, Any]:
        path = snapshot_dir / DATA_FILE
        if not path.is_file():
            raise ImporterError("snapshot_not_found")
        try:
            data: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
        except ValueError:
            raise ImporterDataError from None
        return data

    def snapshot_version(self, snapshot_dir: Path) -> str | None:
        version = self._read(snapshot_dir).get("version")
        return str(version) if version is not None else None

    def parse(self, snapshot_dir: Path) -> Iterator[Record]:
        data = self._read(snapshot_dir)
        for item in data.get("substances", []):
            yield SubstanceRecord(
                source_key=item["key"],
                market=item["market"],
                name_en=item.get("name_en"),
                name_ru=item.get("name_ru"),
                names=tuple((n["lang"], n["name"]) for n in item.get("names", [])),
            )
        for item in data.get("compositions", []):
            yield CompositionRecord(
                source_key=item["key"],
                market=item["market"],
                form_code=item.get("form_code"),
                form_name_en=item.get("form_name_en"),
                form_name_ru=item.get("form_name_ru"),
                complete=bool(item.get("complete", False)),
                ingredients=tuple(
                    IngredientRecord(
                        substance_key=ing["substance"],
                        strength_value=_decimal(ing.get("strength_value")),
                        strength_unit=ing.get("strength_unit"),
                        per_value=_decimal(ing.get("per_value")),
                        per_unit=ing.get("per_unit"),
                    )
                    for ing in item.get("ingredients", [])
                ),
            )
        for item in data.get("products", []):
            yield ProductRecord(
                source_key=item["key"],
                market=item["market"],
                brand_name=item["brand_name"],
                manufacturer=item.get("manufacturer"),
                country=item.get("country"),
                composition_key=item.get("composition"),
                composition_source=item.get("composition_source"),
                rx_status=item.get("rx_status"),
                registration_number=item.get("registration_number"),
                packages=tuple(
                    PackageRecord(
                        source_key=pkg["key"],
                        description=pkg.get("description"),
                        count=_decimal(pkg.get("count")),
                        count_unit=pkg.get("count_unit"),
                        gtins=tuple(pkg.get("gtins", [])),
                    )
                    for pkg in item.get("packages", [])
                ),
            )


async def ensure_dev_source(session: AsyncSession, code: str) -> None:
    """Register a development source row. Real sources are seeded by migration c0002 only."""
    await session.execute(
        text(
            "INSERT INTO catalog.sources (code, name, license, attribution, url, enabled) "
            "VALUES (:code, :name, :license, :attribution, :url, false) "
            "ON CONFLICT (code) DO NOTHING"
        ),
        {
            "code": code,
            "name": FIXTURE_LICENSE.name,
            "license": FIXTURE_LICENSE.license,
            "attribution": FIXTURE_LICENSE.attribution,
            "url": FIXTURE_LICENSE.url,
        },
    )
