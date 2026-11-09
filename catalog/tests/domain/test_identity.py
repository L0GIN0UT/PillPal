"""Catalog ids are a contract (ADR 0012 section 2): they must never change between releases."""

from __future__ import annotations

from decimal import Decimal
from uuid import NAMESPACE_URL, UUID, uuid5

from catalog.domain.identity import (
    CATALOG_NAMESPACE,
    IngredientKey,
    composition_identity_key,
    consensus_package_id,
    entity_id,
)

SUBSTANCE_A = UUID("00000000-0000-0000-0000-00000000000a")
SUBSTANCE_B = UUID("00000000-0000-0000-0000-00000000000b")


def test_namespace_is_pinned() -> None:
    assert uuid5(NAMESPACE_URL, "https://pillpal.invalid/catalog/v1") == CATALOG_NAMESPACE
    # A literal, so that a change of the formula cannot go unnoticed.
    assert str(CATALOG_NAMESPACE) == "7f5785ad-9084-5838-96ba-979a540a0680"


def test_entity_id_is_a_deterministic_uuid5() -> None:
    expected = uuid5(CATALOG_NAMESPACE, "openfda_ndc:product:0002-1234")
    assert entity_id("openfda_ndc", "product", "0002-1234") == expected
    assert entity_id("openfda_ndc", "product", "0002-1234") == expected


def test_entity_id_depends_on_source_kind_and_key() -> None:
    base = entity_id("rxnorm", "substance", "5640")
    assert entity_id("openfda_ndc", "substance", "5640") != base
    assert entity_id("rxnorm", "composition", "5640") != base
    assert entity_id("rxnorm", "substance", "5641") != base


def test_consensus_package_id_formula() -> None:
    product = UUID("00000000-0000-0000-0000-0000000000c1")
    expected = uuid5(CATALOG_NAMESPACE, f"consensus:package:04607012345677:{product}")
    assert consensus_package_id("04607012345677", product) == expected


def _ingredient(
    substance: UUID, value: str | None, unit: str | None, per: str | None = None
) -> IngredientKey:
    return IngredientKey(
        substance_id=substance,
        strength_value=Decimal(value) if value is not None else None,
        strength_unit=unit,
        per_value=Decimal(per) if per is not None else None,
        per_unit="mL" if per is not None else None,
    )


def test_composition_key_does_not_depend_on_ingredient_order() -> None:
    a = _ingredient(SUBSTANCE_A, "500", "mg")
    b = _ingredient(SUBSTANCE_B, "20", "mg")
    assert composition_identity_key("TAB", [a, b]) == composition_identity_key("TAB", [b, a])


def test_composition_key_is_a_sha256_hex() -> None:
    key = composition_identity_key("TAB", [_ingredient(SUBSTANCE_A, "500", "mg")])
    assert len(key) == 64
    assert set(key) <= set("0123456789abcdef")


def test_composition_key_normalises_numbers_and_units() -> None:
    plain = composition_identity_key("TAB", [_ingredient(SUBSTANCE_A, "500", "mg")])
    padded = composition_identity_key("TAB", [_ingredient(SUBSTANCE_A, "500.00", " MG ")])
    assert plain == padded


def test_composition_key_changes_with_strength_unit_form_and_substance() -> None:
    base = composition_identity_key("TAB", [_ingredient(SUBSTANCE_A, "500", "mg")])
    assert composition_identity_key("TAB", [_ingredient(SUBSTANCE_A, "250", "mg")]) != base
    assert composition_identity_key("TAB", [_ingredient(SUBSTANCE_A, "500", "g")]) != base
    assert composition_identity_key("CAP", [_ingredient(SUBSTANCE_A, "500", "mg")]) != base
    assert composition_identity_key("TAB", [_ingredient(SUBSTANCE_B, "500", "mg")]) != base
    assert composition_identity_key("TAB", [_ingredient(SUBSTANCE_A, "500", "mg", "5")]) != base


def test_composition_key_distinguishes_unknown_strength_from_a_value() -> None:
    known = composition_identity_key("TAB", [_ingredient(SUBSTANCE_A, "1", "mg")])
    unknown = composition_identity_key("TAB", [_ingredient(SUBSTANCE_A, None, None)])
    assert known != unknown


def test_composition_key_without_a_form_is_defined() -> None:
    with_form = composition_identity_key("TAB", [_ingredient(SUBSTANCE_A, "1", "mg")])
    without = composition_identity_key(None, [_ingredient(SUBSTANCE_A, "1", "mg")])
    assert with_form != without
