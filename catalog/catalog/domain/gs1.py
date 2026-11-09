"""GS1 element-string parser (reference implementation).

Specification: ``docs/spec/gtin.md`` sections 4-5; executable contract:
``spec/gtin-vectors/gs1.json``. Only the GTIN (AI 01) and the expiry date (AI 17) are returned.
Lot (AI 10) and serial number (AI 21) are consumed and discarded: the result type has no field
for them, so they cannot be stored, logged or sent anywhere (privacy rule 1).
"""

from __future__ import annotations

import calendar
from dataclasses import dataclass, field
from datetime import date
from typing import Final

from catalog.domain.gtin import GTIN14_LENGTH, Gtin, GtinError, check_digit

GS: Final = "\x1d"
# Symbology identifiers of GS1 element strings (GS1 General Specifications, Table 5-2).
SYMBOLOGY_IDENTIFIERS: Final = ("]d2", "]C1", "]Q3", "]e0")
_AI_GTIN: Final = "01"
_AI_EXPIRY: Final = "17"
_AI_LENGTH: Final = 2
# First two digits of a predefined-length AI -> characters of AI + data (Table 7-6).
_PREDEFINED_LENGTHS: Final[dict[str, int]] = {
    "00": 20,
    "01": 16,
    "02": 16,
    "03": 16,
    "04": 18,
    **dict.fromkeys(("11", "12", "13", "14", "15", "16", "17", "18", "19"), 8),
    "20": 4,
    **dict.fromkeys(("31", "32", "33", "34", "35", "36"), 10),
    "41": 16,
}
# AIs ended by GS (or the end of the data): the owner-approved subset of the variable AIs.
_VARIABLE_AIS: Final = frozenset(
    {"10", "21", "22", "240", "241", "30", "37"}
    | {f"71{n}" for n in range(6)}
    | {f"9{n}" for n in range(10)}
)
_ASCII_DIGITS: Final = frozenset("0123456789")


@dataclass(frozen=True, slots=True)
class Gs1Result:
    """What is kept of a scanned GS1 element string. Deliberately has no lot or serial field.

    ``repr`` shows neither the GTIN nor the expiry (a scan may identify a private medicine).
    """

    gtin: Gtin = field(repr=False)
    expiry: date | None = field(repr=False)
    partial: bool


def _is_digits(value: str) -> bool:
    return all(ch in _ASCII_DIGITS for ch in value)


def _strip_prefixes(data: str) -> str:
    for identifier in SYMBOLOGY_IDENTIFIERS:
        if data.startswith(identifier):
            return data[len(identifier) :]
    return data


def _variable_ai(data: str, pos: int) -> str | None:
    for length in (3, 2):
        candidate = data[pos : pos + length]
        if candidate in _VARIABLE_AIS:
            return candidate
    return None


def _parse_expiry(value: str) -> date | None:
    if not _is_digits(value):
        return None
    year, month, day = 2000 + int(value[:2]), int(value[2:4]), int(value[4:])
    if not 1 <= month <= 12:
        return None
    last_day = calendar.monthrange(year, month)[1]
    if day == 0:
        day = last_day
    return date(year, month, day) if day <= last_day else None


def _read_gtin(data: str, pos: int) -> Gtin:
    value = data[pos + _AI_LENGTH : pos + _AI_LENGTH + GTIN14_LENGTH]
    if GS in value or len(value) < GTIN14_LENGTH:
        raise GtinError("invalid_length")
    if not _is_digits(value):
        raise GtinError("invalid_characters")
    if check_digit(value[:-1]) != value[-1]:
        raise GtinError("invalid_check_digit")
    return Gtin(gtin14=value, source_length=GTIN14_LENGTH)


def _predefined_element(data: str, pos: int) -> str | None:
    """The whole numeric predefined-length element at ``pos``, or None when malformed."""
    length = _PREDEFINED_LENGTHS.get(data[pos : pos + _AI_LENGTH])
    if length is None:
        return None
    element = data[pos : pos + length]
    return element if len(element) == length and _is_digits(element) else None


def parse_gs1(data: str) -> Gs1Result:
    """Extracts GTIN and expiry from a scanned GS1 element string.

    Raises ``GtinError`` with ``unsupported_format`` when there is no usable AI 01, or with the
    GTIN error codes when AI 01 is present but malformed. After a valid AI 01 the first unknown
    or malformed element ends the parse and sets ``partial``.
    """
    if data.startswith("]"):
        data = _strip_prefixes(data)
    gtin: Gtin | None = None
    expiry: date | None = None
    pos = 0
    while True:
        while pos < len(data) and data[pos] == GS:
            pos += 1
        if pos >= len(data):
            return _result(gtin, expiry, partial=False)
        prefix = data[pos : pos + _AI_LENGTH]
        if prefix == _AI_GTIN and gtin is None:
            gtin = _read_gtin(data, pos)
            pos += len(_AI_GTIN) + GTIN14_LENGTH
        elif (element := _predefined_element(data, pos)) is not None:
            if prefix == _AI_EXPIRY and gtin is not None:
                expiry = _parse_expiry(element[_AI_LENGTH:])
            pos += len(element)
        elif prefix in _PREDEFINED_LENGTHS:
            return _result(gtin, expiry, partial=True)  # malformed
        elif _variable_ai(data, pos) is not None:
            end = data.find(GS, pos)
            pos = len(data) if end < 0 else end
        else:
            return _result(gtin, expiry, partial=True)  # unknown AI


def _result(gtin: Gtin | None, expiry: date | None, *, partial: bool) -> Gs1Result:
    if gtin is None:
        raise GtinError("unsupported_format")
    return Gs1Result(gtin=gtin, expiry=expiry, partial=partial)
