"""Runs spec/gtin-vectors/gs1.json against the catalog reference implementation."""

from __future__ import annotations

from typing import Any

import pytest

from catalog.domain.gs1 import parse_gs1
from catalog.domain.gtin import GtinError
from tests.gtin_vector_helpers import MIN_CASES, load_cases

CASES = load_cases("gs1.json")


def _run(raw: str) -> dict[str, Any]:
    try:
        result = parse_gs1(raw)
    except GtinError as exc:
        return {"error": exc.code}
    return {
        "gtin14": result.gtin.gtin14,
        "classification": result.gtin.classification,
        "expiry": None if result.expiry is None else result.expiry.isoformat(),
        "partial": result.partial,
    }


def test_vectors_are_loaded() -> None:
    assert len(CASES) >= MIN_CASES


@pytest.mark.parametrize("case", CASES)
def test_vector(case: dict[str, Any]) -> None:
    assert _run(case["input"]) == case["expected"]
