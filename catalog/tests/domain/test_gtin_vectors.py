"""Runs spec/gtin-vectors/normalize.json against the catalog reference implementation.

The backend (subset) and the Dart core run the same file; all must pass unchanged.
"""

from __future__ import annotations

from typing import Any

import pytest

from catalog.domain.gtin import GtinError, gtin14_to_gtin13, ndc_to_gtin14, normalize
from tests.gtin_vector_helpers import MIN_CASES, load_cases

CASES = load_cases("normalize.json")


def _run(case: dict[str, Any]) -> dict[str, Any]:
    op, raw = case["op"], case["input"]
    try:
        if op == "normalize":
            gtin = normalize(raw)
            return {
                "gtin14": gtin.gtin14,
                "source_length": gtin.source_length,
                "classification": gtin.classification,
            }
        if op == "gtin14_to_gtin13":
            return {"gtin13": gtin14_to_gtin13(raw)}
        if op == "ndc_to_gtin14":
            return {"gtin14": ndc_to_gtin14(raw)}
    except GtinError as exc:
        return {"error": exc.code}
    raise AssertionError(f"unknown op {op!r}")


def test_vectors_are_loaded() -> None:
    assert len(CASES) >= MIN_CASES


@pytest.mark.parametrize("case", CASES)
def test_vector(case: dict[str, Any]) -> None:
    assert _run(case) == case["expected"]
