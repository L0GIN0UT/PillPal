#!/usr/bin/env python3
"""Structural validator for the shared test vectors.

Run from the repository root:  python spec/validate_vectors.py

Standard library only. It checks the *shape* and *internal consistency* of
spec/schedule-vectors/*.json (see spec/schedule-vectors/README.md and
schema.json) and of spec/dose-state-vectors/*.json (see that directory's
README.md and schema.json); it does not re-implement the engines. Correctness
of expected values is established by hand derivation and by the Python and
Dart test suites.
Exit status: 0 when all files are valid, 1 otherwise.
"""

from __future__ import annotations

import json
import re
import sys
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from collections.abc import Callable
from typing import Any

VECTORS_DIR = Path(__file__).resolve().parent / "schedule-vectors"
DOSE_STATE_DIR = Path(__file__).resolve().parent / "dose-state-vectors"
DOSE_STATE_FILES = ("marks.json", "snooze.json", "missed.json")
DOSE_STATE_MIN_CASES = 30
MAX_SNOOZE = timedelta(hours=24)
REQUIRED_FILES = (
    "daily.json",
    "weekdays.json",
    "interval.json",
    "course.json",
    "as_needed.json",
    "dst.json",
    "timezones.json",
    "invalid.json",
)
INVALID_FILE = "invalid.json"
MIN_TOTAL_CASES = 30
MAX_WINDOW = timedelta(days=400)
# The Dart `timezone` database has no transitions after 2037, so instants for
# later dates are not guaranteed to agree between implementations.
MAX_VECTOR_YEAR = 2037

KINDS = {"daily", "weekdays", "interval_days", "as_needed"}
UNITS = {
    "tablet",
    "capsule",
    "ml",
    "mg",
    "drop",
    "puff",
    "sachet",
    "unit",
    "injection",
    "other",
}
NAME_RE = re.compile(r"^[a-z0-9_]+$")
INSTANT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
KEY_RE = re.compile(r"^(?P<sid>.+)/(?P<date>\d{4}-\d{2}-\d{2})T(?P<time>\d{2}:\d{2})$")
TIME_RE = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
AMOUNT_RE = re.compile(r"^(0|[1-9][0-9]{0,5})(\.[0-9]{1,3})?$")
NORMALISED_AMOUNT_RE = re.compile(r"^(0|[1-9][0-9]{0,5})(\.[0-9]{0,2}[1-9])?$")


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def error(self, where: str, message: str) -> None:
        self.errors.append(f"{where}: {message}")


def parse_instant(value: Any) -> datetime | None:
    if not isinstance(value, str) or not INSTANT_RE.match(value):
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
    except ValueError:
        return None


def normalise_amount(amount: str) -> str:
    if "." in amount:
        amount = amount.rstrip("0").rstrip(".")
    return amount


def check_keys(
    where: str, obj: dict[str, Any], required: set[str], optional: set[str], report: Report
) -> None:
    missing = required - obj.keys()
    unknown = obj.keys() - required - optional
    if missing:
        report.error(where, f"missing keys {sorted(missing)}")
    if unknown:
        report.error(where, f"unknown keys {sorted(unknown)}")


def slot_doses(where: str, rule: dict[str, Any], report: Report) -> dict[str, tuple[str, str]]:
    """Light sanity check of a rule used in a valid case; returns time -> dose."""
    if rule.get("v") != 1 or isinstance(rule.get("v"), bool):
        report.error(where, "rule.v must be 1")
    if rule.get("kind") not in KINDS:
        report.error(where, f"rule.kind must be one of {sorted(KINDS)}")
    times = rule.get("times")
    doses: dict[str, tuple[str, str]] = {}
    if not isinstance(times, list):
        report.error(where, "rule.times must be an array")
        return doses
    for slot in times:
        if not isinstance(slot, dict) or not isinstance(slot.get("dose"), dict):
            report.error(where, "rule.times entries must be {time, dose} objects")
            continue
        time, dose = slot.get("time"), slot["dose"]
        amount, unit = dose.get("amount"), dose.get("unit")
        if not (isinstance(time, str) and TIME_RE.match(time)):
            report.error(where, f"slot time {time!r} is not HH:MM")
            continue
        if not (isinstance(amount, str) and AMOUNT_RE.match(amount)) or unit not in UNITS:
            report.error(where, f"slot {time} has an invalid dose {dose!r}")
            continue
        doses[time] = (normalise_amount(amount), unit)
    if rule.get("kind") == "as_needed" and times:
        report.error(where, "as_needed rule must have empty times")
    return doses


def check_valid_case(where: str, case: dict[str, Any], report: Report) -> None:
    check_keys(
        where,
        case,
        {"name", "schedule_id", "rule", "tz", "window", "expected"},
        {"description"},
        report,
    )
    sid = case.get("schedule_id")
    if not isinstance(sid, str) or not sid:
        report.error(where, "schedule_id must be a non-empty string")
        return
    if not isinstance(case.get("tz"), str) or not case["tz"]:
        report.error(where, "tz must be a non-empty IANA zone name")
    rule = case.get("rule")
    if not isinstance(rule, dict):
        report.error(where, "rule must be an object")
        return
    doses = slot_doses(where, rule, report)

    window = case.get("window")
    if not isinstance(window, dict):
        report.error(where, "window must be an object")
        return
    check_keys(where + ".window", window, {"from", "to"}, set(), report)
    start, end = parse_instant(window.get("from")), parse_instant(window.get("to"))
    if start is None or end is None:
        report.error(where, "window.from/to must be 'YYYY-MM-DDTHH:MM:SSZ'")
        return
    if end < start:
        report.error(where, "window.to is before window.from")
    if end - start > MAX_WINDOW:
        report.error(where, "window is longer than 400 days")

    expected = case.get("expected")
    if not isinstance(expected, list):
        report.error(where, "expected must be an array")
        return
    if rule.get("kind") == "as_needed" and expected:
        report.error(where, "as_needed must expect no occurrences")
    previous: tuple[datetime, str] | None = None
    seen: set[str] = set()
    for i, occ in enumerate(expected):
        w = f"{where}.expected[{i}]"
        if not isinstance(occ, dict):
            report.error(w, "must be an object")
            continue
        check_keys(w, occ, {"key", "at_utc", "dose_amount", "dose_unit"}, set(), report)
        key = occ.get("key")
        m = KEY_RE.match(key) if isinstance(key, str) else None
        if m is None or m.group("sid") != sid:
            report.error(w, f"key {key!r} is not '{sid}/YYYY-MM-DDTHH:MM'")
            continue
        try:
            nominal = date.fromisoformat(m.group("date"))
        except ValueError:
            report.error(w, f"key has an invalid date {m.group('date')!r}")
            continue
        if nominal.year > MAX_VECTOR_YEAR:
            report.error(w, f"vectors must not use dates after {MAX_VECTOR_YEAR}")
        slot_time = m.group("time")
        if not TIME_RE.match(slot_time):
            report.error(w, f"key has an invalid time {slot_time!r}")
        if key in seen:
            report.error(w, f"duplicate key {key}")
        seen.add(key)
        at = parse_instant(occ.get("at_utc"))
        if at is None:
            report.error(w, "at_utc must be 'YYYY-MM-DDTHH:MM:SSZ'")
            continue
        if not start <= at < end:
            report.error(w, "at_utc is outside the half-open window [from, to)")
        # at_utc = nominal wall time - some UTC offset, and offsets lie in -12..+14 h
        # (in a DST gap it is the pre-transition offset, still in that range).
        wall = datetime.combine(nominal, datetime.strptime(slot_time, "%H:%M").time(), tzinfo=UTC)
        if not wall - timedelta(hours=14) <= at <= wall + timedelta(hours=12):
            report.error(w, "at_utc is implausibly far from the nominal local time")
        amount, unit = occ.get("dose_amount"), occ.get("dose_unit")
        if not isinstance(amount, str) or not NORMALISED_AMOUNT_RE.match(amount):
            report.error(w, f"dose_amount {amount!r} is not a normalised decimal string")
        if unit not in UNITS:
            report.error(w, f"dose_unit {unit!r} is not a known unit")
        if slot_time in doses and doses[slot_time] != (amount, unit):
            report.error(w, f"dose does not match the rule slot {slot_time}: {doses[slot_time]}")
        elif slot_time not in doses:
            report.error(w, f"rule has no slot at {slot_time}")
        current = (at, key)
        if previous is not None and current < previous:
            report.error(w, "expected is not sorted by (at_utc, key)")
        previous = current


def check_invalid_case(where: str, case: dict[str, Any], report: Report) -> None:
    check_keys(where, case, {"name", "rule", "error"}, {"description"}, report)
    if case.get("error") is not True:
        report.error(where, "error must be true")


def check_file(
    path: Path,
    names: set[str],
    report: Report,
    check_case: Callable[[str, dict[str, Any], Report], None] | None = None,
) -> int:
    where = path.name
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        report.error(where, f"cannot parse JSON: {exc}")
        return 0
    if not isinstance(data, dict):
        report.error(where, "top level must be an object")
        return 0
    check_keys(where, data, {"description", "cases"}, {"$schema"}, report)
    cases = data.get("cases")
    if not isinstance(cases, list) or not cases:
        report.error(where, "cases must be a non-empty array")
        return 0
    for i, case in enumerate(cases):
        w = f"{where}#{i}"
        if not isinstance(case, dict):
            report.error(w, "case must be an object")
            continue
        name = case.get("name")
        if not isinstance(name, str) or not NAME_RE.match(name):
            report.error(w, f"name {name!r} must match {NAME_RE.pattern}")
        else:
            w = f"{where}:{name}"
            if name in names:
                report.error(w, "duplicate case name")
            names.add(name)
        if "description" in case and not isinstance(case["description"], str):
            report.error(w, "description must be a string")
        if check_case is not None:
            check_case(w, case, report)
        elif path.name == INVALID_FILE:
            check_invalid_case(w, case, report)
        else:
            check_valid_case(w, case, report)
    return len(cases)


# --- dose-state vectors (docs/spec/dose-state.md) --------------------------------

PRECISE_INSTANT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$")
EVENT_TYPES = {"taken", "skipped", "snoozed", "undo"}
MARK_TYPES = {"taken", "skipped"}
INSTANT_FORMAT = "'YYYY-MM-DDTHH:MM:SS[.ffffff]Z'"


def parse_precise_instant(value: Any) -> datetime | None:
    """UTC instant with an optional 1..6 digit fraction (microseconds)."""
    if not isinstance(value, str) or not PRECISE_INSTANT_RE.match(value):
        return None
    pattern = "%Y-%m-%dT%H:%M:%S.%fZ" if "." in value else "%Y-%m-%dT%H:%M:%SZ"
    try:
        return datetime.strptime(value, pattern).replace(tzinfo=UTC)
    except ValueError:
        return None


def check_key_format(where: str, key: Any, report: Report) -> None:
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


def check_dose_event(where: str, event: Any, ids: set[str], report: Report) -> None:
    if not isinstance(event, dict):
        report.error(where, "event must be an object")
        return
    check_keys(
        where,
        event,
        {"id", "type", "at", "occurrence_key"},
        {"target_event_id", "snooze_until"},
        report,
    )
    event_id = event.get("id")
    if not isinstance(event_id, str) or not event_id:
        report.error(where, "id must be a non-empty string")
    elif event_id in ids:
        report.error(where, f"duplicate event id {event_id!r}")
    else:
        ids.add(event_id)
    kind = event.get("type")
    if kind not in EVENT_TYPES:
        report.error(where, f"type must be one of {sorted(EVENT_TYPES)}")
    at = parse_precise_instant(event.get("at"))
    if at is None:
        report.error(where, f"at must be {INSTANT_FORMAT}")
    if event.get("occurrence_key") is not None:
        check_key_format(where, event.get("occurrence_key"), report)
    target = event.get("target_event_id")
    if (kind == "undo") != (target is not None):
        report.error(where, "target_event_id is required for undo and forbidden otherwise")
    if target is not None and (not isinstance(target, str) or not target):
        report.error(where, "target_event_id must be a non-empty string")
    until_raw = event.get("snooze_until")
    if (kind == "snoozed") != (until_raw is not None):
        report.error(where, "snooze_until is required for snoozed and forbidden otherwise")
    if until_raw is not None:
        until = parse_precise_instant(until_raw)
        if until is None:
            report.error(where, f"snooze_until must be {INSTANT_FORMAT}")
        elif at is not None and not at < until <= at + MAX_SNOOZE:
            report.error(where, "snooze_until must be after 'at' and at most 24 hours later")


def check_expected_mark(
    where: str, mark: Any, events: list[dict[str, Any]], report: Report
) -> None:
    if not isinstance(mark, dict):
        report.error(where, "expected.mark must be null or an object")
        return
    check_keys(where + ".expected.mark", mark, {"event_id", "type", "at"}, set(), report)
    by_id = {e["id"]: e for e in events if isinstance(e.get("id"), str)}
    source = by_id.get(mark.get("event_id"))
    if source is None or source.get("type") not in MARK_TYPES:
        report.error(where, "expected.mark.event_id must be a taken/skipped event of the case")
    elif (source.get("type"), source.get("at")) != (mark.get("type"), mark.get("at")):
        report.error(where, "expected.mark type/at differ from its event")


def check_expected_state(
    where: str,
    expected: Any,
    events: list[dict[str, Any]],
    occurrence_at: datetime,
    report: Report,
) -> tuple[bool, datetime | None]:
    """Checks expected.{mark,snooze_until,due}; returns (has_mark, due)."""
    if not isinstance(expected, dict):
        report.error(where, "expected must be an object")
        return False, None
    check_keys(where + ".expected", expected, {"mark", "snooze_until", "due"}, set(), report)
    mark = expected.get("mark")
    if mark is not None:
        check_expected_mark(where, mark, events, report)
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


def check_missed_probe(
    where: str, probe: Any, has_mark: bool, due: datetime | None, report: Report
) -> None:
    if not isinstance(probe, dict):
        report.error(where, "must be an object")
        return
    check_keys(where, probe, {"now", "grace_minutes", "expected"}, set(), report)
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


def check_dose_state_case(where: str, case: dict[str, Any], report: Report) -> None:
    check_keys(
        where,
        case,
        {"name", "occurrence_key", "occurrence_at", "events", "expected"},
        {"description", "missed"},
        report,
    )
    check_key_format(where, case.get("occurrence_key"), report)
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
        check_dose_event(f"{where}.events[{i}]", event, ids, report)
    if not all(isinstance(e, dict) for e in events):
        return
    has_mark, due = check_expected_state(
        where, case.get("expected"), events, occurrence_at, report
    )
    probes = case.get("missed")
    if probes is not None and (not isinstance(probes, list) or not probes):
        report.error(where, "missed must be a non-empty array")
    elif probes is not None:
        for i, probe in enumerate(probes):
            check_missed_probe(f"{where}.missed[{i}]", probe, has_mark, due, report)


def check_dose_state_dir(report: Report) -> int:
    names: set[str] = set()
    total = 0
    present = sorted(p.name for p in DOSE_STATE_DIR.glob("*.json") if p.name != "schema.json")
    for required in DOSE_STATE_FILES:
        if required not in present:
            report.error(required, "required dose-state vector file is missing")
    for name in present:
        total += check_file(DOSE_STATE_DIR / name, names, report, check_dose_state_case)
    if total < DOSE_STATE_MIN_CASES:
        report.error(
            "dose-state vectors",
            f"only {total} cases, at least {DOSE_STATE_MIN_CASES} required",
        )
    return total


def main() -> int:
    report = Report()
    names: set[str] = set()
    total = 0
    present = sorted(p.name for p in VECTORS_DIR.glob("*.json") if p.name != "schema.json")
    for required in REQUIRED_FILES:
        if required not in present:
            report.error(required, "required vector file is missing")
    for name in present:
        total += check_file(VECTORS_DIR / name, names, report)
    if total < MIN_TOTAL_CASES:
        report.error("vectors", f"only {total} cases, at least {MIN_TOTAL_CASES} required")
    dose_state_total = check_dose_state_dir(report)
    for line in report.errors:
        print(f"ERROR {line}", file=sys.stderr)
    if report.errors:
        print(f"{len(report.errors)} error(s) in {VECTORS_DIR.parent}", file=sys.stderr)
        return 1
    print(f"OK: {total} schedule cases in {len(present)} files")
    print(f"OK: {dose_state_total} dose-state cases in {len(DOSE_STATE_FILES)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
