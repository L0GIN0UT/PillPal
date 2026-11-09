"""Checks of spec/gtin-vectors/*.json (docs/spec/gtin.md).

Used by validate_vectors.py; standard library only. Checks the shape of a case and
that its hand-derived expectations agree with the input (zero padding, source
length, check digits of the example GTINs). It does not re-implement
classification or the element-string parser. It also asserts that no expected
result carries a lot or a serial number (docs/spec/gtin.md section 5.3).
"""

from __future__ import annotations

import re
from datetime import date
from typing import Any, Protocol

ASCII_DIGITS = re.compile(r"^[0-9]*$")
FORBIDDEN_KEYS = {"serial", "lot", "serial_number", "batch"}
NORMALIZE_OPS = {"normalize", "gtin14_to_gtin13", "ndc_to_gtin14"}
CLASSIFICATIONS = {"shareable", "restricted"}
NORMALIZE_ERRORS = {"invalid_length", "invalid_characters", "invalid_check_digit"}
GS1_ERRORS = NORMALIZE_ERRORS | {"unsupported_format"}
SOURCE_LENGTHS = {8, 12, 13, 14}
EXPIRY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class ErrorSink(Protocol):
    def error(self, where: str, message: str) -> None: ...


def check_digit(body: str) -> str:
    """GS1 mod-10 check digit of the digits before it (weights 3,1,3,... from the right)."""
    total = sum(int(ch) * (3 if i % 2 == 0 else 1) for i, ch in enumerate(reversed(body)))
    return str((10 - total % 10) % 10)


def has_valid_check_digit(number: str) -> bool:
    return (
        len(number) >= 2
        and ASCII_DIGITS.fullmatch(number) is not None
        and check_digit(number[:-1]) == number[-1]
    )


def _keys(
    where: str, obj: dict[str, Any], required: set[str], optional: set[str], report: ErrorSink
) -> None:
    missing = required - obj.keys()
    unknown = obj.keys() - required - optional
    if missing:
        report.error(where, f"missing keys {sorted(missing)}")
    if unknown:
        report.error(where, f"unknown keys {sorted(unknown)}")


def find_forbidden_keys(value: Any, path: str = "expected") -> list[str]:
    """Paths of every key named like a lot or serial number, at any depth."""
    found: list[str] = []
    if isinstance(value, dict):
        for key, item in value.items():
            if str(key).lower() in FORBIDDEN_KEYS:
                found.append(f"{path}.{key}")
            found.extend(find_forbidden_keys(item, f"{path}.{key}"))
    elif isinstance(value, list):
        for i, item in enumerate(value):
            found.extend(find_forbidden_keys(item, f"{path}[{i}]"))
    return found


def _strip(raw: str) -> str:
    return raw.replace(" ", "").replace("-", "")


def _check_gtin14(where: str, field: str, value: Any, report: ErrorSink) -> bool:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{14}", value):
        report.error(where, f"{field} {value!r} must be 14 ASCII digits")
        return False
    if not has_valid_check_digit(value):
        report.error(where, f"{field} {value} has an invalid check digit")
        return False
    return True


def _check_classification(where: str, value: Any, report: ErrorSink) -> None:
    if value not in CLASSIFICATIONS:
        report.error(where, f"classification {value!r} must be one of {sorted(CLASSIFICATIONS)}")


def _check_normalize_success(
    where: str, raw: str, expected: dict[str, Any], report: ErrorSink
) -> None:
    _keys(where, expected, {"gtin14", "source_length", "classification"}, set(), report)
    _check_classification(where, expected.get("classification"), report)
    length = expected.get("source_length")
    if length not in SOURCE_LENGTHS or isinstance(length, bool):
        report.error(where, f"source_length {length!r} must be one of {sorted(SOURCE_LENGTHS)}")
        return
    if not _check_gtin14(where, "gtin14", expected.get("gtin14"), report):
        return
    stripped = _strip(raw)
    if len(stripped) != length or expected["gtin14"] != stripped.zfill(14):
        report.error(where, "gtin14 / source_length do not follow from the input")


def _check_error(
    where: str, expected: dict[str, Any], allowed: set[str], report: ErrorSink
) -> None:
    _keys(where, expected, {"error"}, set(), report)
    if expected.get("error") not in allowed:
        report.error(where, f"error {expected.get('error')!r} must be one of {sorted(allowed)}")


def _check_error_consistency(where: str, raw: str, code: Any, report: ErrorSink) -> None:
    """invalid_check_digit needs a well-formed number; the other codes must not be one."""
    stripped = _strip(raw)
    well_formed = ASCII_DIGITS.fullmatch(stripped) is not None and len(stripped) in SOURCE_LENGTHS
    if code == "invalid_check_digit" and (not well_formed or has_valid_check_digit(stripped)):
        report.error(where, "invalid_check_digit needs a well-formed number with a wrong digit")
    if code == "invalid_characters" and ASCII_DIGITS.fullmatch(stripped):
        report.error(where, "invalid_characters but the input has only ASCII digits")
    if code == "invalid_length" and (
        ASCII_DIGITS.fullmatch(stripped) is None or len(stripped) in SOURCE_LENGTHS
    ):
        report.error(where, "invalid_length but the input has bad characters or a valid length")


def check_gtin_normalize_case(where: str, case: dict[str, Any], report: ErrorSink) -> None:
    _keys(where, case, {"name", "op", "input", "expected"}, {"description"}, report)
    op = case.get("op")
    raw = case.get("input")
    expected = case.get("expected")
    if op not in NORMALIZE_OPS:
        report.error(where, f"op {op!r} must be one of {sorted(NORMALIZE_OPS)}")
        return
    if not isinstance(raw, str) or not isinstance(expected, dict):
        report.error(where, "input must be a string and expected an object")
        return
    for path in find_forbidden_keys(expected):
        report.error(where, f"{path}: a result must not carry a lot or a serial number")
    if "error" in expected:
        _check_error(where, expected, NORMALIZE_ERRORS, report)
        if op != "ndc_to_gtin14":
            _check_error_consistency(where, raw, expected.get("error"), report)
        return
    if op == "normalize":
        _check_normalize_success(where, raw, expected, report)
    elif op == "gtin14_to_gtin13":
        _keys(where, expected, {"gtin13"}, set(), report)
        _check_gtin13_result(where, raw, expected.get("gtin13"), report)
    else:
        _keys(where, expected, {"gtin14"}, set(), report)
        _check_ndc_result(where, raw, expected.get("gtin14"), report)


def _check_gtin13_result(where: str, raw: str, gtin13: Any, report: ErrorSink) -> None:
    padded = _strip(raw).zfill(14)
    if gtin13 is None:
        if padded[0] == "0":
            report.error(where, "indicator digit 0 has a GTIN-13 form")
        return
    if gtin13 != padded[1:] or padded[0] != "0":
        report.error(where, "gtin13 must be the 14-digit form without its leading zero")
    elif not has_valid_check_digit(gtin13):
        report.error(where, f"gtin13 {gtin13} has an invalid check digit")


def _check_ndc_result(where: str, raw: str, gtin14: Any, report: ErrorSink) -> None:
    if not _check_gtin14(where, "gtin14", gtin14, report):
        return
    digits = _strip(raw)
    if gtin14 != "00" + "3" + digits + check_digit("3" + digits):
        report.error(where, "gtin14 must be '00' + '3' + NDC + check digit")


def check_gtin_gs1_case(where: str, case: dict[str, Any], report: ErrorSink) -> None:
    _keys(where, case, {"name", "input", "expected"}, {"description"}, report)
    raw = case.get("input")
    expected = case.get("expected")
    if not isinstance(raw, str) or not isinstance(expected, dict):
        report.error(where, "input must be a string and expected an object")
        return
    for path in find_forbidden_keys(expected):
        report.error(where, f"{path}: a result must not carry a lot or a serial number")
    if "error" in expected:
        _check_error(where, expected, GS1_ERRORS, report)
        return
    _keys(where, expected, {"gtin14", "classification", "expiry", "partial"}, set(), report)
    _check_gtin14(where, "gtin14", expected.get("gtin14"), report)
    _check_classification(where, expected.get("classification"), report)
    if not isinstance(expected.get("partial"), bool):
        report.error(where, "partial must be a boolean")
    expiry = expected.get("expiry")
    if expiry is not None:
        if not isinstance(expiry, str) or not EXPIRY_RE.match(expiry):
            report.error(where, f"expiry {expiry!r} must be YYYY-MM-DD or null")
        else:
            try:
                date.fromisoformat(expiry)
            except ValueError:
                report.error(where, f"expiry {expiry!r} is not a calendar date")
    if "01" + str(expected.get("gtin14")) not in raw.replace("\x1d", ""):
        report.error(where, "the expected gtin14 does not occur after AI 01 in the input")
