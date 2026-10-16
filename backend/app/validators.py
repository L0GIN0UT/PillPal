"""Reusable pydantic field types."""

from __future__ import annotations

import re
import zoneinfo
from datetime import UTC, datetime, timedelta
from functools import lru_cache
from typing import Annotated

from pydantic import AfterValidator, AwareDatetime, Field, StringConstraints

DEVICE_ID_PATTERN = r"^[A-Za-z0-9._:-]{1,128}$"


@lru_cache(maxsize=1)
def _known_zones() -> frozenset[str]:
    return frozenset(zoneinfo.available_timezones())


def validate_timezone(value: str) -> str:
    if value not in _known_zones():
        raise ValueError("Unknown IANA time zone")
    return value


def _strip_control_chars(value: str) -> str:
    if re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", value):
        raise ValueError("Control characters are not allowed")
    return value


IanaTimezone = Annotated[str, StringConstraints(max_length=64), AfterValidator(validate_timezone)]
DeviceId = Annotated[str, StringConstraints(pattern=DEVICE_ID_PATTERN)]


Name200 = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=200),
    AfterValidator(_strip_control_chars),
]
DisplayName = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=100),
    AfterValidator(_strip_control_chars),
]
ShortText = Annotated[
    str,
    StringConstraints(strip_whitespace=True, max_length=100),
    AfterValidator(_strip_control_chars),
]
UnitText = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=32),
    AfterValidator(_strip_control_chars),
]
Notes = Annotated[
    str,
    StringConstraints(max_length=2000),
    AfterValidator(_strip_control_chars),
]
EventNote = Annotated[
    str,
    StringConstraints(max_length=1000),
    AfterValidator(_strip_control_chars),
]

# Missed-dose alert threshold of a profile: minutes after the due time (TZ §2.5).
MISSED_ALERT_MINUTES_MIN = 5
MISSED_ALERT_MINUTES_MAX = 720
MISSED_ALERT_MINUTES_DEFAULT = 30
# Strict: a JSON boolean, string or float is a client bug, not a number to coerce.
MissedAlertMinutes = Annotated[
    int, Field(strict=True, ge=MISSED_ALERT_MINUTES_MIN, le=MISSED_ALERT_MINUTES_MAX)
]

# Device clocks may run a little fast; anything further ahead is a broken clock
# whose writes would win every last-write-wins comparison for that long.
MAX_FUTURE_SKEW = timedelta(minutes=10)


def _not_far_future(value: datetime) -> datetime:
    if value > datetime.now(UTC) + MAX_FUTURE_SKEW:
        raise ValueError("Timestamp is too far in the future")
    return value


def to_utc(value: datetime) -> datetime:
    return value.astimezone(UTC)


# Client-supplied instants are stored and echoed in UTC.
UtcDatetime = Annotated[AwareDatetime, AfterValidator(to_utc)]
ClientTimestamp = Annotated[UtcDatetime, AfterValidator(_not_far_future)]
