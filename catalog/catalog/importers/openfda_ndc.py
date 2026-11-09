"""openFDA National Drug Code directory (bulk ``drug-ndc`` JSON, CC0), docs/phase4-plan.md 4.4.

One product NDC is one Product; ``packaging[]`` gives Packages and GTINs (NDC -> GTIN-14,
``ndc.py``). A composition is the ``active_ingredients`` plus ``dosage_form`` of a product:

- with ``openfda.rxcui`` the product points at the RxNorm SCD compositions (any of the listed
  rxcuis: the loader links the first that exists; SBD and pack ids simply do not exist there), and
  no local composition is written;
- without, the product gets a source-local composition. openFDA has no key for it, so the key is
  a versioned hash of the strings of the product itself (name, strength, form), kept apart from
  ``identity_key``. Products with the same composition share it.

The file is parsed incrementally in three passes (substances, compositions, products) because the
loader needs the levels in that order; memory is bounded by one record plus the sets of keys
already emitted. Substances are keyed by normalized ingredient name: ``active_ingredients`` carries
no UNII per ingredient and ``openfda.unii`` is not aligned with it.
"""

from __future__ import annotations

import hashlib
import re
from collections import Counter
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

import httpx

from catalog.domain.identity import IngredientKey, composition_identity_key
from catalog.importers.base import (
    CompositionRecord,
    ImporterError,
    IngredientRecord,
    LicenseNote,
    PackageRecord,
    ProductRecord,
    Record,
    SnapshotManifest,
    SubstanceRecord,
)
from catalog.importers.ids import substance_id
from catalog.importers.jsonstream import read_json_member, stream_json_array
from catalog.importers.ndc import MAX_DESCRIPTION_CHARS, package_count, package_gtin14
from catalog.importers.openfda_fetch import (
    MAX_PARTITION_BYTES,
    MAX_SNAPSHOT_BYTES,
    fetch_snapshot,
)
from catalog.importers.rxnorm_index import rxcui_order
from catalog.importers.strength import Strength, parse_strength

OPENFDA_SOURCE = "openfda_ndc"
MARKET = "us"
RXNORM_SOURCE = "rxnorm"
DATA_GLOB = "drug-ndc-*.json"
RESULTS_KEY = "results"
PRODUCT_TYPES = {"HUMAN PRESCRIPTION DRUG": "rx", "HUMAN OTC DRUG": "otc"}
MAX_TEXT_CHARS = 200
MAX_RXCUIS = 20
LOCAL_KEY_PREFIX = "local:v1:"
# Product NDC configurations as printed: 4-4, 5-3 and 5-4.
PRODUCT_NDC = re.compile(r"\d{4}-\d{4}|\d{5}-\d{3,4}", re.ASCII)
_PARTITION_FILE = re.compile(r"drug-ndc-(\d{4})-of-(\d{4})\.json", re.ASCII)
_RXCUI = re.compile(r"\d{1,12}", re.ASCII)


@dataclass(frozen=True)
class _Ingredient:
    key: str  # normalized name
    display: str
    strength: Strength | None


@dataclass(frozen=True)
class _Product:
    ndc: str
    name: str
    labeler: str | None
    rx_status: str
    form: str | None
    ingredients: tuple[_Ingredient, ...]
    rxcuis: tuple[str, ...]
    packaging: tuple[Any, ...]


def _text(value: Any, limit: int = MAX_TEXT_CHARS) -> str | None:
    if not isinstance(value, str):
        return None
    stripped = " ".join(value.split())
    if not 0 < len(stripped) <= limit or "\x00" in stripped:
        return None
    try:
        stripped.encode("utf-8")  # a lone surrogate cannot be stored or logged
    except UnicodeEncodeError:
        return None
    return stripped


def _display(name: str) -> str:
    return name.lower().capitalize() if name.isupper() else name


def _ingredient(raw: Any) -> _Ingredient | None:
    name = _text(raw.get("name")) if isinstance(raw, dict) else None
    if name is None:
        return None
    strength = raw.get("strength")
    parsed = parse_strength(strength) if isinstance(strength, str) else None
    return _Ingredient(key=f"name:{name.casefold()}", display=_display(name), strength=parsed)


def _rxcuis(raw: Any) -> tuple[str, ...]:
    values = raw.get("rxcui") if isinstance(raw, dict) else None
    if not isinstance(values, list):
        return ()
    found = [v for v in values if isinstance(v, str) and _RXCUI.fullmatch(v)]
    return tuple(dict.fromkeys(found))[:MAX_RXCUIS]


def _skip_reason(raw: Any) -> str | None:
    if not isinstance(raw, dict):
        return "invalid_product"
    ndc = raw.get("product_ndc")
    if not isinstance(ndc, str) or PRODUCT_NDC.fullmatch(ndc) is None:
        return "invalid_product"
    if raw.get("finished") is not True:
        return "not_finished"
    if raw.get("product_type") not in PRODUCT_TYPES:
        return "unsupported_product_type"
    return None


def _skip(skipped: Counter[str] | None, reason: str) -> None:
    if skipped is not None:
        skipped[reason] += 1


def _normalize(raw: Any, skipped: Counter[str] | None) -> _Product | None:
    reason = _skip_reason(raw)
    if reason is not None:
        _skip(skipped, reason)
        return None
    name = _text(raw.get("brand_name")) or _text(raw.get("generic_name"))
    if name is None:
        _skip(skipped, "invalid_product")
        return None
    ingredients = raw.get("active_ingredients")
    found = [_ingredient(i) for i in ingredients] if isinstance(ingredients, list) else []
    packaging = raw.get("packaging")
    return _Product(
        ndc=raw["product_ndc"],
        name=name,
        labeler=_text(raw.get("labeler_name")),
        rx_status=PRODUCT_TYPES[raw["product_type"]],
        form=_text(raw.get("dosage_form")),
        ingredients=tuple(i for i in found if i is not None),
        rxcuis=_rxcuis(raw.get("openfda")),
        packaging=tuple(packaging) if isinstance(packaging, list) else (),
    )


def _canonical_ingredients(product: _Product) -> dict[str, _Ingredient]:
    return {i.key: i for i in product.ingredients}  # one row per substance, as the loader does


def _number(value: Decimal | None) -> str:
    return "-" if value is None else format(value.normalize(), "f")


def _line(key: str, strength: Strength | None) -> str:
    if strength is None:
        return f"{key}|-|-|-|-"
    per_unit = (strength.per_unit or "-").lower()
    return "|".join(
        (key, _number(strength.value), strength.unit.lower(), _number(strength.per_value), per_unit)
    )


def _local_key(product: _Product) -> str:
    lines = sorted(_line(k, i.strength) for k, i in _canonical_ingredients(product).items())
    payload = "\n".join([f"form:{(product.form or '-').casefold()}", *lines])
    return LOCAL_KEY_PREFIX + hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _identity(product: _Product) -> str:
    """The loader's identity key of the product's composition (to fold equal compositions)."""
    keys = [
        IngredientKey(
            substance_id(OPENFDA_SOURCE, key),
            i.strength.value if i.strength else None,
            i.strength.unit if i.strength else None,
            i.strength.per_value if i.strength else None,
            i.strength.per_unit if i.strength else None,
        )
        for key, i in _canonical_ingredients(product).items()
    ]
    return composition_identity_key(product.form.casefold() if product.form else None, keys)


def _composition_record(product: _Product, key: str) -> CompositionRecord:
    ingredients = tuple(
        IngredientRecord(
            substance_key=i.key,
            strength_value=i.strength.value if i.strength else None,
            strength_unit=i.strength.unit if i.strength else None,
            per_value=i.strength.per_value if i.strength else None,
            per_unit=i.strength.per_unit if i.strength else None,
        )
        for i in _canonical_ingredients(product).values()
    )
    complete = bool(product.form) and all(i.strength_value is not None for i in ingredients)
    return CompositionRecord(
        source_key=key,
        market=MARKET,
        form_code=product.form.casefold() if product.form else None,
        form_name_en=_display(product.form) if product.form else None,
        ingredients=ingredients,
        complete=complete,
    )


class OpenFdaNdcImporter:
    source = OPENFDA_SOURCE
    license = LicenseNote(
        name="openFDA National Drug Code directory",
        license="CC0 1.0 (U.S. Government work); not for clinical decisions",
        attribution="Product data: openFDA (U.S. FDA)",
        url="https://open.fda.gov/",
    )

    def __init__(
        self,
        transport: httpx.BaseTransport | None = None,
        now: Callable[[], datetime] | None = None,
        max_download_bytes: int = MAX_PARTITION_BYTES,
        max_snapshot_bytes: int = MAX_SNAPSHOT_BYTES,
    ) -> None:
        self._transport = transport
        self._now = now or (lambda: datetime.now(UTC))
        self._max_download_bytes = max_download_bytes
        self._max_snapshot_bytes = max_snapshot_bytes
        self.skipped: Counter[str] = Counter()

    def ensure_enabled(self) -> None:
        return None

    def fetch(self, dest: Path) -> SnapshotManifest:
        return fetch_snapshot(
            dest,
            transport=self._transport,
            retrieved_at=self._now(),
            max_partition_bytes=self._max_download_bytes,
            max_snapshot_bytes=self._max_snapshot_bytes,
        )

    def _files(self, snapshot_dir: Path) -> list[Path]:
        """The data files, which must be the complete set ``1..N`` of ``N`` partitions."""
        found = {}
        for path in snapshot_dir.glob(DATA_GLOB):
            match = _PARTITION_FILE.fullmatch(path.name)
            if match is not None and path.is_file():
                found[int(match.group(1))] = (int(match.group(2)), path)
        if not found:
            raise ImporterError("snapshot_not_found")
        totals = {total for total, _ in found.values()}
        if len(totals) != 1 or set(found) != set(range(1, totals.pop() + 1)):
            # A partial snapshot would withdraw every product it lacks.
            raise ImporterError("snapshot_incomplete")
        return [found[number][1] for number in sorted(found)]

    def snapshot_version(self, snapshot_dir: Path) -> str | None:
        meta = read_json_member(self._files(snapshot_dir)[0], "meta")
        updated = meta.get("last_updated") if isinstance(meta, dict) else None
        return updated if isinstance(updated, str) and len(updated) <= MAX_TEXT_CHARS else None

    def _products(self, snapshot_dir: Path, skipped: Counter[str] | None) -> Iterator[_Product]:
        seen: set[str] = set()
        for path in self._files(snapshot_dir):
            for raw in stream_json_array(path, RESULTS_KEY):
                product = _normalize(raw, skipped)
                if product is None:
                    continue
                if product.ndc in seen:
                    _skip(skipped, "duplicate_product")
                    continue
                seen.add(product.ndc)
                yield product

    def parse(self, snapshot_dir: Path) -> Iterator[Record]:
        self.skipped = Counter()
        local_keys: dict[str, str] = {}  # identity_key -> first local key
        yield from self._substances(snapshot_dir)
        yield from self._compositions(snapshot_dir, local_keys)
        yield from self._product_records(snapshot_dir, local_keys)

    def _substances(self, snapshot_dir: Path) -> Iterator[SubstanceRecord]:
        seen: set[str] = set()
        for product in self._products(snapshot_dir, None):
            for item in product.ingredients:
                if item.key not in seen:
                    seen.add(item.key)
                    yield SubstanceRecord(source_key=item.key, market=MARKET, name_en=item.display)

    def _compositions(
        self, snapshot_dir: Path, local_keys: dict[str, str]
    ) -> Iterator[CompositionRecord]:
        for product in self._products(snapshot_dir, None):
            if not product.ingredients:
                continue
            identity = _identity(product)
            if identity in local_keys:
                continue
            local_keys[identity] = key = _local_key(product)
            yield _composition_record(product, key)

    def _product_records(
        self, snapshot_dir: Path, local_keys: dict[str, str]
    ) -> Iterator[ProductRecord]:
        seen_packages: set[str] = set()
        for product in self._products(snapshot_dir, self.skipped):
            yield self._product_record(product, local_keys, seen_packages)

    def _product_record(
        self, product: _Product, local_keys: dict[str, str], seen_packages: set[str]
    ) -> ProductRecord:
        packages = tuple(
            p
            for p in (self._package(raw, seen_packages) for raw in product.packaging)
            if p is not None
        )
        common: dict[str, Any] = {
            "source_key": product.ndc,
            "market": MARKET,
            "brand_name": product.name,
            "manufacturer": product.labeler,
            "rx_status": product.rx_status,
            "packages": packages,
        }
        # RxNorm SCDs first (numeric order), the product's own composition last, so a product
        # whose rxcuis are not in the Prescribable subset still links.
        refs = [(RXNORM_SOURCE, r) for r in sorted(product.rxcuis, key=rxcui_order)]
        if product.ingredients:
            refs.append((OPENFDA_SOURCE, local_keys[_identity(product)]))
        if not refs:
            return ProductRecord(**common)
        return ProductRecord(
            **common,
            composition_source=refs[0][0],
            composition_key=refs[0][1],
            composition_alternatives=tuple(refs[1:]),
        )

    def _package(self, raw: Any, seen: set[str]) -> PackageRecord | None:
        ndc = _text(raw.get("package_ndc")) if isinstance(raw, dict) else None
        if ndc is None:
            return None
        if raw.get("sample") is True:
            self.skipped["sample_package"] += 1
            return None
        if ndc in seen:
            self.skipped["duplicate_package"] += 1  # a package NDC belongs to one product
            return None
        seen.add(ndc)
        description = _text(raw.get("description"), MAX_DESCRIPTION_CHARS)
        parsed = package_count(description)
        gtin = package_gtin14(ndc)
        return PackageRecord(
            source_key=ndc,
            description=description,
            count=parsed[0] if parsed else None,
            count_unit=parsed[1] if parsed else None,
            gtins=(gtin,) if gtin else (),
        )
