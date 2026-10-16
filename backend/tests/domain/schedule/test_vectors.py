"""Runs every shared vector in spec/schedule-vectors/ against the Python engine.

The Dart package runs the same files; both must pass unchanged.
"""

from __future__ import annotations

import json
import os
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest
from pydantic import ValidationError

from app.domain.schedule import ScheduleRule, expand

VECTORS_DIR = Path(
    os.environ.get(
        "PILLPAL_VECTORS_DIR",
        Path(__file__).resolve().parents[4] / "spec" / "schedule-vectors",
    )
)
INVALID_FILE = "invalid.json"


def _load_cases() -> tuple[list[Any], list[Any]]:
    files = sorted(p for p in VECTORS_DIR.glob("*.json") if p.name != "schema.json")
    if not files:
        raise RuntimeError(f"no schedule vectors found in {VECTORS_DIR}")
    valid: list[Any] = []
    invalid: list[Any] = []
    for path in files:
        cases = json.loads(path.read_text(encoding="utf-8"))["cases"]
        target = invalid if path.name == INVALID_FILE else valid
        target.extend(pytest.param(case, id=f"{path.stem}:{case['name']}") for case in cases)
    return valid, invalid


VALID_CASES, INVALID_CASES = _load_cases()


def _instant(value: str) -> datetime:
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def _format(value: datetime) -> str:
    return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def test_vector_suite_is_large_enough() -> None:
    assert len(VALID_CASES) + len(INVALID_CASES) >= 30


@pytest.mark.parametrize("case", VALID_CASES)
def test_valid_vector(case: dict[str, Any]) -> None:
    rule = ScheduleRule.model_validate(case["rule"])
    occurrences = expand(
        rule,
        schedule_id=case["schedule_id"],
        tz=case["tz"],
        start=_instant(case["window"]["from"]),
        end=_instant(case["window"]["to"]),
    )
    actual = [
        {
            "key": occ.key,
            "at_utc": _format(occ.at_utc),
            "dose_amount": occ.dose_amount,
            "dose_unit": occ.dose_unit,
        }
        for occ in occurrences
    ]
    assert actual == case["expected"]


@pytest.mark.parametrize("case", INVALID_CASES)
def test_invalid_vector(case: dict[str, Any]) -> None:
    with pytest.raises(ValidationError):
        ScheduleRule.model_validate(case["rule"])


@pytest.mark.parametrize("case", VALID_CASES)
def test_canonical_form_round_trips(case: dict[str, Any]) -> None:
    rule = ScheduleRule.model_validate(case["rule"])
    canonical = rule.to_json()
    again = ScheduleRule.model_validate(json.loads(json.dumps(canonical)))
    assert again == rule
    assert again.to_json() == canonical
