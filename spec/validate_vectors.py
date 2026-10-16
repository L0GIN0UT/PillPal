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
from collections.abc import Callable
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any

import dose_state_checks

VECTORS_DIR = Path(__file__).resolve().parent / "schedule-vectors"
DOSE_STATE_DIR = Path(__file__).resolve().parent / "dose-state-vectors"
DOSE_STATE_FILES = ("marks.json", "snooze.json", "missed.json")
DOSE_STATE_MIN_CASES = 30
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


def check_dose_state_dir(report: Report) -> tuple[int, int]:
    """Returns (cases, files) of spec/dose-state-vectors."""
    names: set[str] = set()
    total = 0
    present = sorted(p.name for p in DOSE_STATE_DIR.glob("*.json") if p.name != "schema.json")
    for required in DOSE_STATE_FILES:
        if required not in present:
            report.error(required, "required dose-state vector file is missing")
    for name in present:
        total += check_file(
            DOSE_STATE_DIR / name, names, report, dose_state_checks.check_dose_state_case
        )
    if total < DOSE_STATE_MIN_CASES:
        report.error(
            "dose-state vectors",
            f"only {total} cases, at least {DOSE_STATE_MIN_CASES} required",
        )
    return total, len(present)


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
    dose_state_total, dose_state_files = check_dose_state_dir(report)
    for line in report.errors:
        print(f"ERROR {line}", file=sys.stderr)
    if report.errors:
        print(f"{len(report.errors)} error(s) in {VECTORS_DIR.parent}", file=sys.stderr)
        return 1
    print(f"OK: {total} schedule cases in {len(present)} files")
    print(f"OK: {dose_state_total} dose-state cases in {dose_state_files} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
