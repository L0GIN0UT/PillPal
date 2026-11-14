"""Reusable pydantic field types."""

from __future__ import annotations

import re
import zoneinfo
from datetime import UTC, datetime, timedelta
from functools import lru_cache
from typing import Annotated

from pydantic import (
    AfterValidator,
    AwareDatetime,
    Field,
    StringConstraints,
    TypeAdapter,
    ValidationError,
)

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
# A person's own name (the ``self`` profile): required at sign-up and shown to relatives, so it is
# short and readable on one line. Not unique. Managed profiles keep ``DisplayName``.
PERSON_NAME_MIN = 2
PERSON_NAME_MAX = 20
PersonName = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True, min_length=PERSON_NAME_MIN, max_length=PERSON_NAME_MAX
    ),
    AfterValidator(_strip_control_chars),
]
_PERSON_NAME: TypeAdapter[str] = TypeAdapter(PersonName)


def is_person_name(value: str) -> bool:
    """Whether ``value`` passes ``PersonName`` (a stored rename of the ``self`` profile)."""
    try:
        _PERSON_NAME.validate_python(value)
    except ValidationError:
        return False
    return True


ShortText = Annotated[
    str,
    StringConstraints(strip_whitespace=True, max_length=100),
    AfterValidator(_strip_control_chars),
]
IngredientName = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=100),
    AfterValidator(_strip_control_chars),
]
IngredientStrength = Annotated[
    str,
    StringConstraints(strip_whitespace=True, max_length=50),
    AfterValidator(_strip_control_chars),
]
# GTIN-14 as stored on a medication: shape only. Restricted numbers (store codes, variable
# measure) are allowed here because the GTIN stays private to the user; the catalog contract
# (docs/spec/gtin.md) decides what may leave the device.
Gtin14 = Annotated[str, StringConstraints(pattern=r"^[0-9]{14}$")]
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
