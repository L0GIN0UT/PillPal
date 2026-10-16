"""Runs every shared vector in spec/dose-state-vectors/ against the Python reference.

The Dart package runs the same files; both must pass unchanged.
"""

from __future__ import annotations

import json
import os
import random
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest

from app.domain.dose_state import (
    DoseEvent,
    occurrence_state,
    occurrence_states_by_key,
    summarize_events,
)

VECTORS_DIR = Path(
    os.environ.get(
        "PILLPAL_DOSE_STATE_VECTORS_DIR",
        Path(__file__).resolve().parents[3] / "spec" / "dose-state-vectors",
    )
)


def _load_cases() -> list[Any]:
    files = sorted(p for p in VECTORS_DIR.glob("*.json") if p.name != "schema.json")
    if not files:
        raise RuntimeError(f"no dose-state vectors found in {VECTORS_DIR}")
    cases: list[Any] = []
    for path in files:
        data = json.loads(path.read_text(encoding="utf-8"))
        cases.extend(pytest.param(case, id=f"{path.stem}:{case['name']}") for case in data["cases"])
    return cases


CASES = _load_cases()


def _instant(value: str) -> datetime:
    pattern = "%Y-%m-%dT%H:%M:%S.%fZ" if "." in value else "%Y-%m-%dT%H:%M:%SZ"
    return datetime.strptime(value, pattern).replace(tzinfo=UTC)


def _optional_instant(value: str | None) -> datetime | None:
    return None if value is None else _instant(value)


def _events(case: dict[str, Any]) -> list[DoseEvent]:
    return [
        DoseEvent(
            id=raw["id"],
            type=raw["type"],
            at=_instant(raw["at"]),
            occurrence_key=raw["occurrence_key"],
            target_event_id=raw.get("target_event_id"),
            snooze_until=_optional_instant(raw.get("snooze_until")),
        )
        for raw in case["events"]
    ]


def _orderings(events: list[DoseEvent]) -> list[list[DoseEvent]]:
    shuffled = list(events)
    random.Random(20261016).shuffle(shuffled)
    return [events, list(reversed(events)), shuffled]


def test_vector_suite_is_large_enough() -> None:
    assert len(CASES) >= 30


@pytest.mark.parametrize("case", CASES)
def test_vector_state(case: dict[str, Any]) -> None:
    occurrence_at = _instant(case["occurrence_at"])
    expected = case["expected"]
    for events in _orderings(_events(case)):
        state = occurrence_state(events, case["occurrence_key"])

        if expected["mark"] is None:
            assert state.mark is None
        else:
            assert state.mark is not None
            assert state.mark.event_id == expected["mark"]["event_id"]
            assert state.mark.type == expected["mark"]["type"]
            assert state.mark.at == _instant(expected["mark"]["at"])
        assert state.snooze_until == _optional_instant(expected["snooze_until"])
        assert state.due_at(occurrence_at) == _instant(expected["due"])


@pytest.mark.parametrize("case", CASES)
def test_vector_missed_probes(case: dict[str, Any]) -> None:
    occurrence_at = _instant(case["occurrence_at"])
    for events in _orderings(_events(case)):
        state = occurrence_state(events, case["occurrence_key"])
        for probe in case.get("missed", []):
            actual = state.is_missed(
                occurrence_at=occurrence_at,
                now=_instant(probe["now"]),
                grace=timedelta(minutes=probe["grace_minutes"]),
            )
            assert actual is probe["expected"], probe


@pytest.mark.parametrize("case", CASES)
def test_vector_state_by_key_agrees(case: dict[str, Any]) -> None:
    """Folding every key at once gives the same state for the case's key."""
    events = _events(case)
    single = occurrence_state(events, case["occurrence_key"])
    grouped = occurrence_states_by_key(events).get(case["occurrence_key"])
    if single.mark is None and single.snooze_until is None:
        assert grouped is None
    else:
        assert grouped == single


@pytest.mark.parametrize("case", CASES)
def test_vector_summary_of_the_keys_own_events_agrees(case: dict[str, Any]) -> None:
    """summarize_events on pre-grouped events (undos included) equals the keyed fold."""
    events = _events(case)
    own = [e for e in events if e.occurrence_key == case["occurrence_key"]]
    foreign_undos = [
        e for e in events if e.type == "undo" and e.occurrence_key != case["occurrence_key"]
    ]
    assert summarize_events(own + foreign_undos) == occurrence_state(events, case["occurrence_key"])
