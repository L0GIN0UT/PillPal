"""Deterministic catalog identity (ADR 0012 sections 1 and 2). Pure: no IO, no clock.

Ids are UUIDv5 over a pinned namespace, so every regional catalog computes the same id for the same
source record and a re-import of a snapshot changes nothing. The namespace string is a contract:
changing it orphans every user medication that references a catalog row.
"""

from __future__ import annotations

import hashlib
from collections.abc import Iterable
from dataclasses import dataclass
from decimal import Decimal
from typing import Literal
from uuid import NAMESPACE_URL, UUID, uuid5

CATALOG_NAMESPACE = uuid5(NAMESPACE_URL, "https://pillpal.invalid/catalog/v1")

EntityKind = Literal["substance", "composition", "product", "package"]
_UNKNOWN = "-"


def entity_id(source: str, kind: EntityKind, source_key: str) -> UUID:
    """Id of a source record: ``uuid5(NS, "<source>:<kind>:<source_key>")``."""
    return uuid5(CATALOG_NAMESPACE, f"{source}:{kind}:{source_key}")


def consensus_package_id(gtin14: str, product_id: UUID) -> UUID:
    """The one package a consensus link creates for a GTIN and a product (ADR 0014)."""
    return uuid5(CATALOG_NAMESPACE, f"consensus:package:{gtin14}:{product_id}")


@dataclass(frozen=True)
class IngredientKey:
    """One ingredient of a composition as it takes part in the identity."""

    substance_id: UUID
    strength_value: Decimal | None
    strength_unit: str | None
    per_value: Decimal | None = None
    per_unit: str | None = None


def _number(value: Decimal | None) -> str:
    if value is None:
        return _UNKNOWN
    # 500, 500.0 and 5E+2 are the same strength.
    return format(value.normalize(), "f")


def _unit(unit: str | None) -> str:
    return unit.strip().lower() if unit and unit.strip() else _UNKNOWN


def _ingredient_line(item: IngredientKey) -> str:
    return "|".join(
        (
            str(item.substance_id),
            _number(item.strength_value),
            _unit(item.strength_unit),
            _number(item.per_value),
            _unit(item.per_unit),
        )
    )


def composition_identity_key(form_code: str | None, ingredients: Iterable[IngredientKey]) -> str:
    """sha256 of the form and the canonical ingredient set; independent of ingredient order."""
    lines = sorted(_ingredient_line(item) for item in ingredients)
    form = form_code.strip().lower() if form_code and form_code.strip() else _UNKNOWN
    payload = "\n".join([f"form:{form}", *lines])
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()
