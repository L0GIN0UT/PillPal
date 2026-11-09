"""Runs spec/gtin-vectors/normalize.json against the catalog reference implementation.

The backend (subset) and the Dart core run the same file; all must pass unchanged.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import pytest

from catalog.domain.gtin import GtinError, gtin14_to_gtin13, ndc_to_gtin14, normalize

VECTORS_DIR = Path(
    os.environ.get(
        "PILLPAL_GTIN_VECTORS_DIR",
        Path(__file__).resolve().parents[3] / "spec" / "gtin-vectors",
    )
)


def _load_cases() -> list[Any]:
    path = VECTORS_DIR / "normalize.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    return [pytest.param(case, id=case["name"]) for case in data["cases"]]


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
    assert len(_load_cases()) >= 40


@pytest.mark.parametrize("case", _load_cases())
def test_vector(case: dict[str, Any]) -> None:
    assert _run(case) == case["expected"]
