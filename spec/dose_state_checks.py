"""Checks of spec/dose-state-vectors/*.json (docs/spec/dose-state.md).

Used by validate_vectors.py; standard library only. Checks the shape of a case and
that its hand-derived expected values agree with each other (``due`` follows from
``snooze_until``, ``missed`` verdicts follow from ``due`` and the mark). It does not
re-implement the fold. Write-path invariants (an undo has a target, a snooze has
``snooze_until``) are deliberately not required: the contract defines a result for
every input, and vectors pin the unusual ones.
"""

from __future__ import annotations

import re
from datetime import UTC, date, datetime, timedelta
from typing import Any, Protocol

PRECISE_INSTANT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$")
KEY_RE = re.compile(r"^.+/(?P<date>\d{4}-\d{2}-\d{2})T(?P<time>\d{2}:\d{2})$")
TIME_RE = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
# Ids are ASCII and compared ordinally (docs/spec/dose-state.md section 1.2).
ID_RE = re.compile(r"^[a-z0-9-]+$")
EVENT_TYPES = {"taken", "skipped", "snoozed", "undo"}
MARK_TYPES = {"taken", "skipped"}
INSTANT_FORMAT = "'YYYY-MM-DDTHH:MM:SS[.ffffff]Z'"


class ErrorSink(Protocol):
    def error(self, where: str, message: str) -> None: ...


def _check_keys(
    where: str, obj: dict[str, Any], required: set[str], optional: set[str], report: ErrorSink
) -> None:
    missing = required - obj.keys()
    unknown = obj.keys() - required - optional
    if missing:
        report.error(where, f"missing keys {sorted(missing)}")
    if unknown:
        report.error(where, f"unknown keys {sorted(unknown)}")


def parse_precise_instant(value: Any) -> datetime | None:
    """UTC instant with an optional 1..6 digit fraction (microseconds)."""
    if not isinstance(value, str) or not PRECISE_INSTANT_RE.match(value):
        return None
    pattern = "%Y-%m-%dT%H:%M:%S.%fZ" if "." in value else "%Y-%m-%dT%H:%M:%SZ"
    try:
        return datetime.strptime(value, pattern).replace(tzinfo=UTC)
    except ValueError:
        return None


def _check_key_format(where: str, key: Any, report: ErrorSink) -> None:
    match = KEY_RE.match(key) if isinstance(key, str) else None
    if match is None:
        report.error(where, f"occurrence key {key!r} is not '<id>/YYYY-MM-DDTHH:MM'")
        return
    try:
        date.fromisoformat(match.group("date"))
    except ValueError:
        report.error(where, f"occurrence key {key!r} has an invalid date")
    if not TIME_RE.match(match.group("time")):
        report.error(where, f"occurrence key {key!r} has an invalid time")


def _check_id(where: str, field: str, value: Any, report: ErrorSink) -> None:
    if not isinstance(value, str) or not ID_RE.match(value):
        report.error(where, f"{field} {value!r} must match {ID_RE.pattern}")


def _check_dose_event(where: str, event: Any, ids: set[str], report: ErrorSink) -> None:
    if not isinstance(event, dict):
        report.error(where, "event must be an object")
        return
    _check_keys(
        where,
        event,
        {"id", "type", "at", "occurrence_key"},
        {"target_event_id", "snooze_until"},
        report,
    )
    _check_id(where, "id", event.get("id"), report)
    event_id = event.get("id")
    if isinstance(event_id, str):
        if event_id in ids:
            report.error(where, f"duplicate event id {event_id!r}")
        ids.add(event_id)
    if event.get("type") not in EVENT_TYPES:
        report.error(where, f"type must be one of {sorted(EVENT_TYPES)}")
    if parse_precise_instant(event.get("at")) is None:
        report.error(where, f"at must be {INSTANT_FORMAT}")
    if event.get("occurrence_key") is not None:
        _check_key_format(where, event.get("occurrence_key"), report)
    if "target_event_id" in event:
        _check_id(where, "target_event_id", event["target_event_id"], report)
    if "snooze_until" in event and parse_precise_instant(event["snooze_until"]) is None:
        report.error(where, f"snooze_until must be {INSTANT_FORMAT}")


def _check_expected_mark(
    where: str, mark: Any, events: list[dict[str, Any]], report: ErrorSink
) -> None:
    if not isinstance(mark, dict):
        report.error(where, "expected.mark must be null or an object")
        return
    _check_keys(where + ".expected.mark", mark, {"event_id", "type", "at"}, set(), report)
    by_id = {e["id"]: e for e in events if isinstance(e.get("id"), str)}
    source = by_id.get(mark.get("event_id"))
    if source is None or source.get("type") not in MARK_TYPES:
        report.error(where, "expected.mark.event_id must be a taken/skipped event of the case")
    elif (source.get("type"), source.get("at")) != (mark.get("type"), mark.get("at")):
        report.error(where, "expected.mark type/at differ from its event")


def _check_expected_state(
    where: str,
    expected: Any,
    events: list[dict[str, Any]],
    occurrence_at: datetime,
    report: ErrorSink,
) -> tuple[bool, datetime | None]:
    """Checks expected.{mark,snooze_until,due}; returns (has_mark, due)."""
    if not isinstance(expected, dict):
        report.error(where, "expected must be an object")
        return False, None
    _check_keys(where + ".expected", expected, {"mark", "snooze_until", "due"}, set(), report)
    mark = expected.get("mark")
    if mark is not None:
        _check_expected_mark(where, mark, events, report)
    snooze_raw = expected.get("snooze_until")
    snooze = None
    if snooze_raw is not None:
        snooze = parse_precise_instant(snooze_raw)
        sources = {e.get("snooze_until") for e in events if e.get("type") == "snoozed"}
        if snooze is None:
            report.error(where, "expected.snooze_until must be null or an instant")
        elif snooze_raw not in sources:
            report.error(where, "expected.snooze_until is not the snooze_until of any event")
    due = parse_precise_instant(expected.get("due"))
    if due is None:
        report.error(where, "expected.due must be an instant")
    elif due != max(occurrence_at, snooze or occurrence_at):
        report.error(where, "expected.due is not max(occurrence_at, expected.snooze_until)")
    return mark is not None, due


def _check_missed_probe(
    where: str, probe: Any, has_mark: bool, due: datetime | None, report: ErrorSink
) -> None:
    if not isinstance(probe, dict):
        report.error(where, "must be an object")
        return
    _check_keys(where, probe, {"now", "grace_minutes", "expected"}, set(), report)
    now = parse_precise_instant(probe.get("now"))
    grace = probe.get("grace_minutes")
    verdict = probe.get("expected")
    if now is None:
        report.error(where, f"now must be {INSTANT_FORMAT}")
    if not isinstance(grace, int) or isinstance(grace, bool) or grace < 0:
        report.error(where, "grace_minutes must be a non-negative integer")
    if not isinstance(verdict, bool):
        report.error(where, "expected must be a boolean")
    if now is None or due is None or not isinstance(grace, int) or not isinstance(verdict, bool):
        return
    # Hand-derived verdicts are cross-checked against the case's own expected.due.
    if verdict != (not has_mark and now >= due + timedelta(minutes=grace)):
        report.error(where, "expected does not follow from expected.due and the mark")


def check_dose_state_case(where: str, case: dict[str, Any], report: ErrorSink) -> None:
    _check_keys(
        where,
        case,
        {"name", "occurrence_key", "occurrence_at", "events", "expected"},
        {"description", "missed"},
        report,
    )
    _check_key_format(where, case.get("occurrence_key"), report)
    occurrence_at = parse_precise_instant(case.get("occurrence_at"))
    if occurrence_at is None:
        report.error(where, f"occurrence_at must be {INSTANT_FORMAT}")
        return
    events = case.get("events")
    if not isinstance(events, list):
        report.error(where, "events must be an array")
        return
    ids: set[str] = set()
    for i, event in enumerate(events):
        _check_dose_event(f"{where}.events[{i}]", event, ids, report)
    if not all(isinstance(e, dict) for e in events):
        return
    has_mark, due = _check_expected_state(
        where, case.get("expected"), events, occurrence_at, report
    )
    probes = case.get("missed")
    if probes is not None and (not isinstance(probes, list) or not probes):
        report.error(where, "missed must be a non-empty array")
    elif probes is not None:
        for i, probe in enumerate(probes):
            _check_missed_probe(f"{where}.missed[{i}]", probe, has_mark, due, report)
