"""RxNorm Prescribable Content importer (RRF files, NLM terms), docs/phase4-plan.md 4.4.

Ingredients (IN) and precise ingredients (PIN) become substances; each semantic clinical drug
(SCD) becomes a composition whose ingredients and strengths come from its components (SCDC) and
whose form is its dose form (DF). RxNorm carries no products: US products come from openFDA,
which links to these compositions by rxcui (``openfda_ndc.py``).

An SCD that cannot be described faithfully is skipped and counted, never guessed: no component,
a component whose ingredient is not in the files, or a composition equal to a lower rxcui's.
"""

from __future__ import annotations

import re
from collections import Counter
from collections.abc import Callable, Iterator
from datetime import UTC, datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path

import httpx

from catalog.domain.identity import IngredientKey, composition_identity_key
from catalog.importers.base import (
    CompositionRecord,
    ImporterError,
    IngredientRecord,
    LicenseNote,
    Record,
    SnapshotManifest,
    SubstanceRecord,
)
from catalog.importers.ids import substance_id
from catalog.importers.rrf import iter_rrf
from catalog.importers.rxnorm_fetch import MAX_ARCHIVE_BYTES, fetch_snapshot, find_rrf_dir
from catalog.importers.rxnorm_index import (
    AVAILABLE_STRENGTH,
    BOSS_DENOM_UNIT,
    BOSS_DENOM_VALUE,
    BOSS_NUM_UNIT,
    BOSS_NUM_VALUE,
    RXNORM_VOCABULARY,
    RxNormIndex,
    read_attributes,
    read_concepts,
    read_relations,
    rxcui_order,
)
from catalog.importers.strength import MAX_UNIT_CHARS, Strength, parse_strength

RXNORM_SOURCE = "rxnorm"
MARKET = "us"
CORE_FILES = ("RXNCONSO.RRF", "RXNREL.RRF", "RXNSAT.RRF")
VERSION_FILE = "RXNSAB.RRF"
SAB_RSAB = 3
SAB_SVER = 6
SAB_FIELDS = SAB_SVER + 1
_VERSION = re.compile(r"[0-9A-Za-z._-]{1,40}", re.ASCII)


def _decimal(text: str | None) -> Decimal | None:
    try:
        return Decimal(text) if text else None
    except InvalidOperation:
        return None


def _boss_strength(attributes: dict[str, str]) -> Strength | None:
    value, unit = _decimal(attributes.get(BOSS_NUM_VALUE)), attributes.get(BOSS_NUM_UNIT, "")
    if value is None or not value.is_finite() or value <= 0 or not 0 < len(unit) <= MAX_UNIT_CHARS:
        return None
    denominator_unit = attributes.get(BOSS_DENOM_UNIT, "")
    if not 0 < len(denominator_unit) <= MAX_UNIT_CHARS:
        return Strength(value, unit)
    per = _decimal(attributes.get(BOSS_DENOM_VALUE)) or Decimal(1)
    if not per.is_finite() or per <= 0:
        return None
    return Strength(value, unit, per, denominator_unit)


def _ingredient_of(index: RxNormIndex, component: str) -> str | None:
    """The ingredient of a component: IN when there is one, else PIN; lowest rxcui if several."""
    found = index.ingredients.get(component) or index.precise.get(component)
    return min(found, key=rxcui_order) if found else None


def _identity(form: str | None, ingredients: tuple[IngredientRecord, ...]) -> str:
    return composition_identity_key(
        form,
        [
            IngredientKey(
                substance_id(RXNORM_SOURCE, i.substance_key),
                i.strength_value,
                i.strength_unit,
                i.per_value,
                i.per_unit,
            )
            for i in ingredients
        ],
    )


class RxNormImporter:
    source = RXNORM_SOURCE
    license = LicenseNote(
        name="RxNorm Prescribable Content",
        license=(
            "NLM RxNorm terms: attribution and disclaimer; the Prescribable subset needs no "
            "UMLS license"
        ),
        attribution="Substance and composition data: RxNorm, U.S. National Library of Medicine",
        url="https://www.nlm.nih.gov/research/umls/rxnorm/",
    )

    def __init__(
        self,
        transport: httpx.BaseTransport | None = None,
        now: Callable[[], datetime] | None = None,
        release: str | None = None,
        expected_sha256: str | None = None,
        max_download_bytes: int = MAX_ARCHIVE_BYTES,
    ) -> None:
        self._transport = transport
        self._now = now or (lambda: datetime.now(UTC))
        self._release = release
        self._expected_sha256 = expected_sha256
        self._max_download_bytes = max_download_bytes
        self.skipped: Counter[str] = Counter()

    def ensure_enabled(self) -> None:
        return None

    def fetch(self, dest: Path) -> SnapshotManifest:
        return fetch_snapshot(
            dest,
            transport=self._transport,
            retrieved_at=self._now(),
            release=self._release,
            expected_sha256=self._expected_sha256,
            max_bytes=self._max_download_bytes,
        )

    def snapshot_version(self, snapshot_dir: Path) -> str | None:
        path = find_rrf_dir(snapshot_dir) / VERSION_FILE
        if not path.is_file():
            return None
        for row in iter_rrf(path, SAB_FIELDS):
            if row[SAB_RSAB] == RXNORM_VOCABULARY and _VERSION.fullmatch(row[SAB_SVER]):
                return row[SAB_SVER]
        return None

    def _index(self, snapshot_dir: Path) -> RxNormIndex:
        folder = find_rrf_dir(snapshot_dir)
        if not all((folder / name).is_file() for name in CORE_FILES):
            raise ImporterError("snapshot_not_found")
        index = RxNormIndex()
        read_concepts(folder / CORE_FILES[0], index)
        read_relations(folder / CORE_FILES[1], index)
        read_attributes(folder / CORE_FILES[2], index)
        return index

    def parse(self, snapshot_dir: Path) -> Iterator[Record]:
        self.skipped = Counter()
        index = self._index(snapshot_dir)
        self.skipped.update(index.dropped)
        for rxcui in index.of_type("IN", "PIN"):
            yield SubstanceRecord(source_key=rxcui, market=MARKET, name_en=index.concepts[rxcui][1])
        seen: set[str] = set()
        for scd in index.of_type("SCD"):
            record = self._composition(index, scd)
            if record is None:
                continue
            identity = _identity(record.form_code, record.ingredients)
            if identity in seen:
                self.skipped["duplicate_composition"] += 1
                continue
            seen.add(identity)
            yield record

    def _composition(self, index: RxNormIndex, scd: str) -> CompositionRecord | None:
        components = sorted(index.components.get(scd, ()), key=rxcui_order)
        if not components:
            self.skipped["no_ingredients"] += 1
            return None
        pairs = [(c, _ingredient_of(index, c)) for c in components]
        if any(ingredient is None for _, ingredient in pairs):
            self.skipped["unknown_ingredient"] += 1
            return None
        fallback = self._available_strength(index, scd) if len(components) == 1 else None
        ingredients = {}
        for component, ingredient in pairs:
            strength = _boss_strength(index.attributes.get(component, {})) or fallback
            ingredients[str(ingredient)] = IngredientRecord(
                substance_key=str(ingredient),
                strength_value=strength.value if strength else None,
                strength_unit=strength.unit if strength else None,
                per_value=strength.per_value if strength else None,
                per_unit=strength.per_unit if strength else None,
            )
        # A SCD has one dose form in practice; if the files list several, the lowest rxcui wins.
        forms = index.dose_forms.get(scd)
        form = min(forms, key=rxcui_order) if forms else None
        complete = form is not None and all(
            i.strength_value is not None for i in ingredients.values()
        )
        return CompositionRecord(
            source_key=scd,
            market=MARKET,
            form_code=form,
            form_name_en=index.concepts[form][1] if form else None,
            ingredients=tuple(ingredients.values()),
            complete=complete,
        )

    @staticmethod
    def _available_strength(index: RxNormIndex, scd: str) -> Strength | None:
        text = index.attributes.get(scd, {}).get(AVAILABLE_STRENGTH)
        return parse_strength(text) if text else None
