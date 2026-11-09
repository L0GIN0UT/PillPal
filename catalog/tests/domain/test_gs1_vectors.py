"""Runs spec/gtin-vectors/gs1.json against the catalog reference implementation."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import pytest

from catalog.domain.gs1 import parse_gs1
from catalog.domain.gtin import GtinError

VECTORS_DIR = Path(
    os.environ.get(
        "PILLPAL_GTIN_VECTORS_DIR",
        Path(__file__).resolve().parents[3] / "spec" / "gtin-vectors",
    )
)


def _load_cases() -> list[Any]:
    data = json.loads((VECTORS_DIR / "gs1.json").read_text(encoding="utf-8"))
    return [pytest.param(case, id=case["name"]) for case in data["cases"]]


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
    assert len(_load_cases()) >= 40


@pytest.mark.parametrize("case", _load_cases())
def test_vector(case: dict[str, Any]) -> None:
    assert _run(case["input"]) == case["expected"]
