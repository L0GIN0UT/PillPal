"""Schedule rule document, version 1 — see docs/spec/schedule.md §1-§2."""

from __future__ import annotations

import re
from datetime import date, datetime
from enum import StrEnum
from typing import Any, Self

from pydantic import (
    BaseModel,
    ConfigDict,
    StrictInt,
    StrictStr,
    field_validator,
    model_validator,
)

RULE_VERSION = 1
MIN_YEAR = 2000
MAX_YEAR = 2199
MIN_INTERVAL_DAYS = 2
MAX_INTERVAL_DAYS = 366
MAX_SLOTS = 24

_DATE_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
_TIME_RE = re.compile(r"([01][0-9]|2[0-3]):[0-5][0-9]")
_AMOUNT_RE = re.compile(r"(0|[1-9][0-9]{0,5})(\.[0-9]{1,3})?")


class RuleKind(StrEnum):
    DAILY = "daily"
    WEEKDAYS = "weekdays"
    INTERVAL_DAYS = "interval_days"
    AS_NEEDED = "as_needed"


class DoseUnit(StrEnum):
    TABLET = "tablet"
    CAPSULE = "capsule"
    ML = "ml"
    MG = "mg"
    DROP = "drop"
    PUFF = "puff"
    SACHET = "sachet"
    UNIT = "unit"
    INJECTION = "injection"
    OTHER = "other"


def _parse_local_date(value: object) -> date:
    if isinstance(value, date) and not isinstance(value, datetime):
        parsed = value
    elif isinstance(value, str) and _DATE_RE.fullmatch(value):
        try:
            parsed = date.fromisoformat(value)
        except ValueError:
            raise ValueError(f"{value!r} is not a valid calendar date") from None
    else:
        raise ValueError("expected a date string 'YYYY-MM-DD'")
    if not MIN_YEAR <= parsed.year <= MAX_YEAR:
        raise ValueError(f"year must be within {MIN_YEAR}..{MAX_YEAR}")
    return parsed


def normalize_amount(amount: str) -> str:
    """Validate a dose amount string and return its normalised form (§1.3)."""
    if not _AMOUNT_RE.fullmatch(amount):
        raise ValueError(
            "amount must be a decimal string like '1', '0.5' or '2.25' "
            "(no sign or exponent, at most 3 fractional digits)"
        )
    if "." in amount:
        amount = amount.rstrip("0").rstrip(".")
    if amount == "0":
        raise ValueError("amount must be greater than zero")
    return amount


class Dose(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    amount: StrictStr
    unit: DoseUnit

    @field_validator("amount")
    @classmethod
    def _check_amount(cls, value: str) -> str:
        return normalize_amount(value)


class TimeSlot(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    time: StrictStr
    dose: Dose

    @field_validator("time")
    @classmethod
    def _check_time(cls, value: str) -> str:
        if not _TIME_RE.fullmatch(value):
            raise ValueError("time must be 'HH:MM' within 00:00..23:59")
        return value

    @property
    def hour(self) -> int:
        return int(self.time[:2])

    @property
    def minute(self) -> int:
        return int(self.time[3:])


class ScheduleRule(BaseModel):
    """A validated, normalised schedule rule (``schedules.rule``, version 1).

    ``model_validate`` raises ``pydantic.ValidationError`` for any rule that
    violates docs/spec/schedule.md §1. ``weekdays`` and ``times`` are sorted.
    """

    model_config = ConfigDict(extra="forbid", frozen=True)

    v: StrictInt
    kind: RuleKind
    start_date: date
    end_date: date | None = None
    weekdays: tuple[StrictInt, ...] | None = None
    interval_days: StrictInt | None = None
    times: tuple[TimeSlot, ...]

    @field_validator("v")
    @classmethod
    def _check_version(cls, value: int) -> int:
        if value != RULE_VERSION:
            raise ValueError(f"unsupported rule version {value}; expected {RULE_VERSION}")
        return value

    @field_validator("start_date", mode="before")
    @classmethod
    def _check_start_date(cls, value: object) -> date:
        return _parse_local_date(value)

    @field_validator("end_date", mode="before")
    @classmethod
    def _check_end_date(cls, value: object) -> date | None:
        return None if value is None else _parse_local_date(value)

    @field_validator("weekdays")
    @classmethod
    def _check_weekdays(cls, value: tuple[int, ...] | None) -> tuple[int, ...] | None:
        if value is None:
            return None
        if not value:
            raise ValueError("weekdays must not be empty")
        if any(not 1 <= day <= 7 for day in value):
            raise ValueError("weekdays must be ISO weekday numbers 1 (Monday) .. 7 (Sunday)")
        if len(set(value)) != len(value):
            raise ValueError("weekdays must not contain duplicates")
        return tuple(sorted(value))

    @field_validator("interval_days")
    @classmethod
    def _check_interval(cls, value: int | None) -> int | None:
        if value is not None and not MIN_INTERVAL_DAYS <= value <= MAX_INTERVAL_DAYS:
            raise ValueError(
                f"interval_days must be within {MIN_INTERVAL_DAYS}..{MAX_INTERVAL_DAYS}"
            )
        return value

    @field_validator("times")
    @classmethod
    def _check_times(cls, value: tuple[TimeSlot, ...]) -> tuple[TimeSlot, ...]:
        if len(value) > MAX_SLOTS:
            raise ValueError(f"at most {MAX_SLOTS} time slots are allowed")
        if len({slot.time for slot in value}) != len(value):
            raise ValueError("time slots must have distinct times")
        return tuple(sorted(value, key=lambda slot: slot.time))

    @model_validator(mode="after")
    def _check_consistency(self) -> Self:
        if self.end_date is not None and self.end_date < self.start_date:
            raise ValueError("end_date must not be before start_date")
        if self.kind is RuleKind.WEEKDAYS:
            if self.weekdays is None:
                raise ValueError("weekdays is required for kind 'weekdays'")
        elif self.weekdays is not None:
            raise ValueError("weekdays is only allowed for kind 'weekdays'")
        if self.kind is RuleKind.INTERVAL_DAYS:
            if self.interval_days is None:
                raise ValueError("interval_days is required for kind 'interval_days'")
        elif self.interval_days is not None:
            raise ValueError("interval_days is only allowed for kind 'interval_days'")
        if self.kind is RuleKind.AS_NEEDED:
            if self.times:
                raise ValueError("times must be empty for kind 'as_needed'")
        elif not self.times:
            raise ValueError("times must not be empty")
        return self

    def occurs_on(self, day: date) -> bool:
        """Whether the local calendar date ``day`` qualifies (§2)."""
        if day < self.start_date or (self.end_date is not None and day > self.end_date):
            return False
        match self.kind:
            case RuleKind.DAILY:
                return True
            case RuleKind.WEEKDAYS:
                return self.weekdays is not None and day.isoweekday() in self.weekdays
            case RuleKind.INTERVAL_DAYS:
                return (
                    self.interval_days is not None
                    and (day - self.start_date).days % self.interval_days == 0
                )
            case RuleKind.AS_NEEDED:
                return False

    def to_json(self) -> dict[str, Any]:
        """Canonical JSON document (§1.5); validating it yields an equal rule."""
        doc: dict[str, Any] = {
            "v": self.v,
            "kind": self.kind.value,
            "start_date": self.start_date.isoformat(),
            "end_date": None if self.end_date is None else self.end_date.isoformat(),
        }
        if self.weekdays is not None:
            doc["weekdays"] = list(self.weekdays)
        if self.interval_days is not None:
            doc["interval_days"] = self.interval_days
        doc["times"] = [
            {"time": slot.time, "dose": {"amount": slot.dose.amount, "unit": slot.dose.unit.value}}
            for slot in self.times
        ]
        return doc
