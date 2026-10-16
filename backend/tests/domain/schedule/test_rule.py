from __future__ import annotations

from datetime import date, datetime
from typing import Any

import pytest
from pydantic import BaseModel, ValidationError

from app.domain.schedule import DoseUnit, RuleKind, ScheduleRule, normalize_amount


def _rule(**overrides: Any) -> dict[str, Any]:
    doc: dict[str, Any] = {
        "v": 1,
        "kind": "daily",
        "start_date": "2026-10-16",
        "times": [{"time": "08:00", "dose": {"amount": "1", "unit": "tablet"}}],
    }
    doc.update(overrides)
    return doc


def test_minimal_daily_rule_defaults() -> None:
    rule = ScheduleRule.model_validate(_rule())
    assert rule.kind is RuleKind.DAILY
    assert rule.start_date == date(2026, 10, 16)
    assert rule.end_date is None
    assert rule.weekdays is None
    assert rule.interval_days is None
    assert rule.times[0].dose.unit is DoseUnit.TABLET


def test_weekdays_and_times_are_sorted() -> None:
    rule = ScheduleRule.model_validate(
        _rule(
            kind="weekdays",
            weekdays=[7, 1, 3],
            times=[
                {"time": "20:00", "dose": {"amount": "0.50", "unit": "ml"}},
                {"time": "08:00", "dose": {"amount": "1", "unit": "ml"}},
            ],
        )
    )
    assert rule.weekdays == (1, 3, 7)
    assert [slot.time for slot in rule.times] == ["08:00", "20:00"]
    assert rule.times[1].dose.amount == "0.5"


def test_canonical_json_omits_fields_of_other_kinds() -> None:
    rule = ScheduleRule.model_validate(_rule(weekdays=None, interval_days=None))
    assert rule.to_json() == {
        "v": 1,
        "kind": "daily",
        "start_date": "2026-10-16",
        "end_date": None,
        "times": [{"time": "08:00", "dose": {"amount": "1", "unit": "tablet"}}],
    }


def test_canonical_json_interval() -> None:
    rule = ScheduleRule.model_validate(
        _rule(kind="interval_days", interval_days=3, end_date="2026-12-31")
    )
    doc = rule.to_json()
    assert doc["interval_days"] == 3
    assert doc["end_date"] == "2026-12-31"
    assert "weekdays" not in doc


def test_model_dump_json_revalidates() -> None:
    rule = ScheduleRule.model_validate(_rule(kind="weekdays", weekdays=[2]))
    assert ScheduleRule.model_validate(rule.model_dump(mode="json")) == rule
    assert ScheduleRule.model_validate(rule.model_dump()) == rule


def test_validates_inside_a_json_request_model() -> None:
    class Body(BaseModel):
        rule: ScheduleRule

    body = Body.model_validate_json(
        '{"rule": {"v": 1, "kind": "interval_days", "start_date": "2026-10-16",'
        ' "interval_days": 2, "times": [{"time": "08:00",'
        ' "dose": {"amount": "1.500", "unit": "mg"}}]}}'
    )
    assert body.rule.times[0].dose.amount == "1.5"
    with pytest.raises(ValidationError):
        Body.model_validate_json(
            '{"rule": {"v": 1, "kind": "interval_days", "start_date": "2026-10-16",'
            ' "interval_days": 2.0, "times": []}}'
        )


def test_rule_is_immutable() -> None:
    rule = ScheduleRule.model_validate(_rule())
    with pytest.raises(ValidationError):
        rule.kind = RuleKind.AS_NEEDED  # type: ignore[misc]


def test_accepts_date_objects_but_not_datetimes() -> None:
    assert ScheduleRule.model_validate(_rule(start_date=date(2026, 10, 16))).start_date == date(
        2026, 10, 16
    )
    with pytest.raises(ValidationError):
        ScheduleRule.model_validate(_rule(start_date=datetime(2026, 10, 16)))


def test_leap_day_is_a_valid_date() -> None:
    assert ScheduleRule.model_validate(_rule(start_date="2028-02-29")).start_date == date(
        2028, 2, 29
    )


def test_twenty_four_slots_allowed_twenty_five_rejected() -> None:
    slots = [{"time": f"{h:02d}:00", "dose": {"amount": "1", "unit": "drop"}} for h in range(24)]
    assert len(ScheduleRule.model_validate(_rule(times=slots)).times) == 24
    slots.append({"time": "23:30", "dose": {"amount": "1", "unit": "drop"}})
    with pytest.raises(ValidationError):
        ScheduleRule.model_validate(_rule(times=slots))


@pytest.mark.parametrize(
    ("raw", "normalised"),
    [
        ("1", "1"),
        ("0.5", "0.5"),
        ("0.50", "0.5"),
        ("2.000", "2"),
        ("10", "10"),
        ("0.001", "0.001"),
        ("999999.999", "999999.999"),
        ("100.10", "100.1"),
    ],
)
def test_normalize_amount(raw: str, normalised: str) -> None:
    assert normalize_amount(raw) == normalised


@pytest.mark.parametrize(
    "raw", ["0", "0.0", "00", "-1", "+1", ".5", "5.", "1e3", "1.2345", "1000000", " 1", "1,5", ""]
)
def test_normalize_amount_rejects(raw: str) -> None:
    with pytest.raises(ValueError, match="amount"):
        normalize_amount(raw)


@pytest.mark.parametrize(
    ("kind", "day", "expected"),
    [
        ("daily", date(2026, 10, 15), False),
        ("daily", date(2026, 10, 16), True),
        ("daily", date(2026, 10, 20), True),
        ("daily", date(2026, 10, 21), False),
        ("as_needed", date(2026, 10, 17), False),
    ],
)
def test_occurs_on_respects_inclusive_course(kind: str, day: date, expected: bool) -> None:
    times = [] if kind == "as_needed" else _rule()["times"]
    rule = ScheduleRule.model_validate(_rule(kind=kind, end_date="2026-10-20", times=times))
    assert rule.occurs_on(day) is expected


def test_occurs_on_interval_is_anchored_at_start_date() -> None:
    rule = ScheduleRule.model_validate(
        _rule(kind="interval_days", interval_days=3, start_date="2026-10-01")
    )
    hits = [d for d in range(1, 32) if rule.occurs_on(date(2026, 10, d))]
    assert hits == [1, 4, 7, 10, 13, 16, 19, 22, 25, 28, 31]
