"""Runs spec/gtin-vectors/normalize.json against the backend's subset.

The backend implements normalize, classify and ndc_to_gtin14. The ``gtin14_to_gtin13`` cases
belong to the catalog reference and the Dart core and are skipped here, visibly; any other op
fails, so a new op cannot be silently ignored.
"""

from __future__ import annotations

from typing import Any

import pytest

from app.domain.gtin import GtinError, ndc_to_gtin14, normalize
from tests.gtin_vector_helpers import MIN_CASES, load_cases

CASES = load_cases("normalize.json")
KNOWN_OPS = {"normalize", "ndc_to_gtin14", "gtin14_to_gtin13"}


def _run(case: dict[str, Any]) -> dict[str, Any]:
    try:
        if case["op"] == "normalize":
            gtin = normalize(case["input"])
            return {
                "gtin14": gtin.gtin14,
                "source_length": gtin.source_length,
                "classification": gtin.classification,
            }
        return {"gtin14": ndc_to_gtin14(case["input"])}
    except GtinError as exc:
        return {"error": exc.code}


def test_vectors_are_loaded() -> None:
    assert len(CASES) >= MIN_CASES


@pytest.mark.parametrize("case", CASES)
def test_vector(case: dict[str, Any]) -> None:
    if case["op"] == "gtin14_to_gtin13":
        pytest.skip("gtin14_to_gtin13: catalog/Dart only")
    assert case["op"] in KNOWN_OPS, f"unknown op {case['op']!r}"
    assert _run(case) == case["expected"]
