"""Properties of the GTIN value type that the vectors cannot express."""

from __future__ import annotations

import dataclasses

import pytest

from catalog.domain.gtin import Gtin, GtinError, classify, normalize


def test_gtin_is_an_immutable_value() -> None:
    gtin = normalize("4006381333931")
    assert gtin == normalize("4 006381 333931")
    assert hash(gtin) == hash(normalize("4006-3813-33931"))
    with pytest.raises(dataclasses.FrozenInstanceError):
        gtin.gtin14 = "0"  # type: ignore[misc]


def test_classify_is_the_classification_property() -> None:
    gtin = Gtin(gtin14="00000000000000", source_length=8)
    assert classify(gtin) == gtin.classification == "restricted"


def test_error_never_echoes_input() -> None:
    with pytest.raises(GtinError) as info:
        normalize("PRIVATE")
    assert info.value.code == "invalid_characters"
    assert "PRIVATE" not in str(info.value)
