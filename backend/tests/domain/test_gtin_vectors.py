"""Runs the backend's subset of spec/gtin-vectors/normalize.json.

The backend implements normalize, classify and ndc_to_gtin14; the ``gtin14_to_gtin13`` cases
belong to the catalog reference and the Dart core. The catalog and Dart suites run all of them.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import pytest

from app.domain.gtin import GtinError, ndc_to_gtin14, normalize

VECTORS_DIR = Path(
    os.environ.get(
        "PILLPAL_GTIN_VECTORS_DIR",
        Path(__file__).resolve().parents[3] / "spec" / "gtin-vectors",
    )
)
SUPPORTED_OPS = {"normalize", "ndc_to_gtin14"}


def _load_cases() -> list[Any]:
    data = json.loads((VECTORS_DIR / "normalize.json").read_text(encoding="utf-8"))
    return [
        pytest.param(case, id=case["name"]) for case in data["cases"] if case["op"] in SUPPORTED_OPS
    ]


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
    assert len(_load_cases()) >= 40


@pytest.mark.parametrize("case", _load_cases())
def test_vector(case: dict[str, Any]) -> None:
    assert _run(case) == case["expected"]
