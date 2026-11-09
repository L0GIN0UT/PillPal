"""Strengths as the sources print them: ``500 mg/1``, ``250 mg/5 mL``, ``5 MG/ML`` (openFDA
``active_ingredients[].strength`` and RxNorm ``RXN_AVAILABLE_STRENGTH``). ``/1`` means "per
dosage unit" and is stored as no denominator; a bare unit after the slash means one of it."""

from __future__ import annotations

import re
from dataclasses import dataclass
from decimal import Decimal

MAX_UNIT_CHARS = 32
MAX_STRENGTH_CHARS = 100
_NUMBER = r"(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?"
_NUMERATOR = re.compile(rf"({_NUMBER})\s*([^\d\s.,].*)", re.ASCII)
_DENOMINATOR = re.compile(rf"({_NUMBER})?\s*([^\d\s.,].*)?", re.ASCII)


@dataclass(frozen=True)
class Strength:
    value: Decimal
    unit: str
    per_value: Decimal | None = None
    per_unit: str | None = None


def _number(text: str) -> Decimal:
    return Decimal(text.replace(",", ""))


def _unit_ok(unit: str) -> bool:
    return 0 < len(unit) <= MAX_UNIT_CHARS


def parse_strength(text: str) -> Strength | None:
    """The strength, or ``None`` when the text does not follow the printed shape."""
    if len(text) > MAX_STRENGTH_CHARS:
        return None
    numerator, _, denominator = text.strip().partition("/")
    found = _NUMERATOR.fullmatch(numerator.strip())
    if found is None:
        return None
    value, unit = _number(found.group(1)), found.group(2).strip()
    if value <= 0 or not _unit_ok(unit):
        return None
    if not denominator.strip():
        return Strength(value, unit)
    parts = _DENOMINATOR.fullmatch(denominator.strip())
    if parts is None:
        return None
    per_text, per_unit = parts.group(1), (parts.group(2) or "").strip()
    per_value = _number(per_text) if per_text else Decimal(1)
    if per_value <= 0:
        return None
    if not per_unit:
        return Strength(value, unit) if per_value == 1 else None
    if not _unit_ok(per_unit):
        return None
    return Strength(value, unit, per_value, per_unit)
