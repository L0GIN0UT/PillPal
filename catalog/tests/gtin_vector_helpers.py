"""Loader of the shared spec/gtin-vectors files (docs/spec/gtin.md section 8)."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import pytest
from _pytest.mark.structures import ParameterSet

MIN_CASES = 40
VECTORS_DIR = Path(
    os.environ.get(
        "PILLPAL_GTIN_VECTORS_DIR",
        Path(__file__).resolve().parents[2] / "spec" / "gtin-vectors",
    )
)


def load_cases(file_name: str) -> list[ParameterSet]:
    """All cases of one vector file as pytest params, ids are the case names."""
    data: dict[str, Any] = json.loads((VECTORS_DIR / file_name).read_text(encoding="utf-8"))
    return [pytest.param(case, id=case["name"]) for case in data["cases"]]
