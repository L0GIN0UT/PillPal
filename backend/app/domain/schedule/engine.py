"""Occurrence expansion — see docs/spec/schedule.md §3-§4.

This is the reference implementation; ``packages/pillpal_core`` (Dart) must
produce identical results for the shared vectors in ``spec/schedule-vectors``.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.domain.schedule.rule import RuleKind, ScheduleRule

MAX_WINDOW = timedelta(days=400)
# Nominal dates whose (DST-shifted) instant can fall into the window lie at
# most this many days outside the window's local dates (§4).
_DATE_MARGIN = timedelta(days=2)
_ONE_DAY = timedelta(days=1)


@dataclass(frozen=True, slots=True)
class Occurrence:
    """One scheduled dose. ``key`` and ``local_*`` are nominal (never DST-shifted)."""

    key: str
    local_date: date
    local_time: str
    at_utc: datetime
    dose_amount: str
    dose_unit: str


def occurrence_key(schedule_id: str, local_date: date, local_time: str) -> str:
    """``"{schedule_id}/{YYYY-MM-DD}T{HH:MM}"`` from the nominal local date and time."""
    return f"{schedule_id}/{local_date.isoformat()}T{local_time}"


def load_zone(name: str) -> ZoneInfo:
    """Resolve an IANA zone name; ``ValueError`` if it is unknown."""
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError, OSError) as exc:
        raise ValueError(f"unknown time zone {name!r}") from exc


def local_to_utc(day: date, hour: int, minute: int, zone: ZoneInfo) -> datetime:
    """Instant of the wall time ``day hour:minute`` in ``zone`` (§3.1).

    ``fold=0`` gives exactly the spec: an ambiguous time maps to the earlier
    instant; a non-existent time is read with the offset in effect before the
    transition (instant = wall time - pre-transition offset).
    """
    local = datetime(day.year, day.month, day.day, hour, minute, fold=0, tzinfo=zone)
    return local.astimezone(UTC)


def _require_aware(value: datetime, name: str) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError(f"{name} must be a timezone-aware datetime")
    return value.astimezone(UTC)


def expand(
    rule: ScheduleRule,
    *,
    schedule_id: str,
    tz: str,
    start: datetime,
    end: datetime,
) -> list[Occurrence]:
    """All occurrences of ``rule`` with ``start <= at_utc < end``.

    ``tz`` is the effective IANA zone (the caller resolves ``tz_mode``). The
    result is sorted by ``at_utc``, then ``key``. Raises ``ValueError`` for an
    empty ``schedule_id``, naive datetimes, ``end < start``, a window longer
    than 400 days or an unknown zone.
    """
    if not schedule_id:
        raise ValueError("schedule_id must be a non-empty string")
    start_utc = _require_aware(start, "start")
    end_utc = _require_aware(end, "end")
    if end_utc < start_utc:
        raise ValueError("end must not be before start")
    if end_utc - start_utc > MAX_WINDOW:
        raise ValueError("window must not exceed 400 days; page through longer ranges")
    zone = load_zone(tz)
    if rule.kind is RuleKind.AS_NEEDED or end_utc == start_utc:
        return []

    first = max(rule.start_date, start_utc.astimezone(zone).date() - _DATE_MARGIN)
    last = end_utc.astimezone(zone).date() + _DATE_MARGIN
    if rule.end_date is not None:
        last = min(last, rule.end_date)

    result: list[Occurrence] = []
    day = first
    while day <= last:
        if rule.occurs_on(day):
            for slot in rule.times:
                at_utc = local_to_utc(day, slot.hour, slot.minute, zone)
                if start_utc <= at_utc < end_utc:
                    result.append(
                        Occurrence(
                            key=occurrence_key(schedule_id, day, slot.time),
                            local_date=day,
                            local_time=slot.time,
                            at_utc=at_utc,
                            dose_amount=slot.dose.amount,
                            dose_unit=slot.dose.unit.value,
                        )
                    )
        day += _ONE_DAY
    result.sort(key=lambda occ: (occ.at_utc, occ.key))
    return result
