"""GTIN normalization and classification (reference implementation).

Specification: ``docs/spec/gtin.md``; executable contract: ``spec/gtin-vectors/``. The Dart
port in ``packages/pillpal_core`` runs the same vectors; the backend carries the subset it
needs (``app/domain/gtin.py``). Pure: no IO, no clock.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Final, Literal

GtinErrorCode = Literal[
    "invalid_length", "invalid_characters", "invalid_check_digit", "unsupported_format"
]
Classification = Literal["shareable", "restricted"]

GTIN14_LENGTH: Final = 14
GTIN_LENGTHS: Final = frozenset({8, 12, 13, 14})
NDC_LENGTH: Final = 10
_NDC_LENGTHS: Final = frozenset({NDC_LENGTH})
# NDC -> UPC-A: GS1 U.P.C. prefix 3 is aligned with the FDA labeler code (GS1 GS, Table 1-6).
NDC_UPC_PREFIX: Final = "3"
# 13-digit prefixes of Restricted Circulation Numbers (docs/spec/gtin.md section 3).
_RESTRICTED_PREFIXES: Final = ("02", "04", "2")
# A gtin14 starting with these zeros lies in the GTIN-8 range: a GTIN-8 padded to 14 digits.
_GTIN8_LENGTH: Final = 8
_GTIN8_PADDING: Final = "0" * (GTIN14_LENGTH - _GTIN8_LENGTH)
_RCN8_FIRST_DIGITS: Final = "02"
_VARIABLE_MEASURE_INDICATOR: Final = "9"
_ASCII_DIGITS: Final = frozenset("0123456789")


class GtinError(ValueError):
    """A GTIN or element string was rejected. The message never contains the input."""

    def __init__(self, code: GtinErrorCode) -> None:
        super().__init__(code)
        self.code: GtinErrorCode = code


@dataclass(frozen=True, slots=True)
class Gtin:
    """A validated GTIN in its 14-digit form plus the length it was written with.

    Construct it through ``normalize`` only: the constructor does not validate. ``source_length``
    is informational (it never changes the classification). The number is not part of ``repr``:
    a scanned code may identify a private medicine and must not reach logs or tracebacks.
    """

    gtin14: str = field(repr=False)
    source_length: int

    @property
    def classification(self) -> Classification:
        """Whether the number may be shared across accounts (docs/spec/gtin.md section 3)."""
        return classify(self)


def check_digit(body: str) -> str:
    """Mod-10 check digit of ``body`` (weights 3, 1, 3, ... from the right)."""
    total = sum(int(ch) * (3 if i % 2 == 0 else 1) for i, ch in enumerate(reversed(body)))
    return str((10 - total % 10) % 10)


def _strip(raw: str) -> str:
    return raw.replace(" ", "").replace("-", "")


def _require_digits_of_length(stripped: str, lengths: frozenset[int]) -> None:
    # Characters are checked before the length; ``str.isdigit`` would accept Unicode digits.
    if not all(ch in _ASCII_DIGITS for ch in stripped):
        raise GtinError("invalid_characters")
    if len(stripped) not in lengths:
        raise GtinError("invalid_length")


def normalize(raw: str) -> Gtin:
    """Strips spaces and hyphens, validates and left-pads to 14 digits."""
    stripped = _strip(raw)
    _require_digits_of_length(stripped, GTIN_LENGTHS)
    if check_digit(stripped[:-1]) != stripped[-1]:
        raise GtinError("invalid_check_digit")
    return Gtin(gtin14=stripped.zfill(GTIN14_LENGTH), source_length=len(stripped))


def classify(gtin: Gtin) -> Classification:
    """``restricted`` for Restricted Circulation Numbers and variable-measure items.

    Reads ``gtin14`` only, so one number has one classification however it was written.
    """
    digits = gtin.gtin14
    if digits.startswith(_GTIN8_PADDING):
        # RCN-8: GS1-8 prefixes 000-099 and 200-299 (the first digit of the GTIN-8).
        restricted = digits[len(_GTIN8_PADDING)] in _RCN8_FIRST_DIGITS
    else:
        # GTIN-13 form without the indicator digit; indicator 9 is variable measure.
        restricted = digits[0] == _VARIABLE_MEASURE_INDICATOR or digits[1:].startswith(
            _RESTRICTED_PREFIXES
        )
    return "restricted" if restricted else "shareable"


def gtin14_to_gtin13(raw: str) -> str | None:
    """The GTIN-13 form of a GTIN, or None when its indicator digit is not 0."""
    gtin14 = normalize(raw).gtin14
    return gtin14[1:] if gtin14[0] == "0" else None


def ndc_to_gtin14(ndc: str) -> str:
    """10-digit NDC -> ``3`` + NDC + check digit (GTIN-12) -> padded to 14 digits."""
    stripped = _strip(ndc)
    _require_digits_of_length(stripped, _NDC_LENGTHS)
    body = NDC_UPC_PREFIX + stripped
    return (body + check_digit(body)).zfill(GTIN14_LENGTH)
