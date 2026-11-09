"""Shared cleaning of Russian source text: names, registration numbers, barcodes, dosages."""

from __future__ import annotations

from collections import Counter
from decimal import Decimal

import pytest

from catalog.domain.gtin import check_digit
from catalog.importers.ru_common import (
    clean_text,
    inn_parts,
    name_key,
    normalize_registration_number,
    parse_barcodes,
    parse_dosages,
)

VALID_13 = "4600000000015"  # synthetic EAN-13 with a valid check digit


def test_clean_text_collapses_whitespace_and_enforces_the_limit() -> None:
    assert clean_text("  Тестамол \u00a0 500\n", 50) == "Тестамол 500"
    assert clean_text("x" * 51, 50) is None
    assert clean_text("", 50) is None
    assert clean_text(None, 50) is None
    assert clean_text(42, 50) is None
    assert clean_text("a\x00b", 50) is None
    assert clean_text("a\ud800b", 50) is None


def test_name_key_folds_case_and_yo() -> None:
    assert name_key("  Ёлка  ТЕСТ ") == "елка тест"


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("ЛП-001234", "ЛП-001234"),
        (" лп\u2013001234 ", "ЛП-001234"),
        ("лп - 001234", "ЛП-001234"),
        ("П N012345/01", "П N012345/01"),
        ("", None),
        (None, None),
        ("x" * 70, None),
    ],
)
def test_registration_numbers_are_compared_in_one_shape(
    raw: str | None, expected: str | None
) -> None:
    assert normalize_registration_number(raw) == expected


def test_barcodes_become_gtin14_and_bad_ones_are_counted() -> None:
    skipped: Counter[str] = Counter()

    found = parse_barcodes(f"{VALID_13}; 4600000000016 ;0200000000004", skipped)

    assert found == ("0" + VALID_13,)
    assert skipped == {"gtin_invalid": 1, "gtin_restricted": 1}


def test_an_empty_barcode_is_not_an_error() -> None:
    skipped: Counter[str] = Counter()
    assert parse_barcodes("  ", skipped) == ()
    assert parse_barcodes(None, skipped) == ()
    assert not skipped


def test_barcode_lengths_8_12_13_14_are_accepted_and_repeats_dropped() -> None:
    skipped: Counter[str] = Counter()
    bodies = ["4600004", "56000000001", "460000000001", "1460000000001"]
    codes = [body + check_digit(body) for body in bodies]
    assert [len(c) for c in codes] == [8, 12, 13, 14]

    got = parse_barcodes(" ".join(codes) + ";" + codes[2] + ";46000000000A", skipped)

    assert got == (*(c.zfill(14) for c in codes[:3]), codes[3])
    assert skipped["gtin_invalid"] == 1


def test_barcode_lists_are_capped() -> None:
    skipped: Counter[str] = Counter()
    many = ";".join([VALID_13] * 3 + ["4600000000015"] * 20)
    assert len(parse_barcodes(many, skipped)) <= 5


def test_inn_parts_split_combinations() -> None:
    assert inn_parts("Амоксициллин + Клавулановая кислота") == [
        "Амоксициллин",
        "Клавулановая кислота",
    ]
    assert inn_parts("  ") == []


def test_dosages_follow_the_ingredients() -> None:
    parsed = parse_dosages("250 мг+125 мг", 2)
    assert [(p.value, p.unit) for p in parsed if p] == [(Decimal(250), "мг"), (Decimal(125), "мг")]
    assert parse_dosages("0,5 г", 1)[0] is not None
    assert parse_dosages("0,5 г", 1)[0].value == Decimal("0.5")  # type: ignore[union-attr]
    liquid = parse_dosages("5 мг/мл", 1)[0]
    assert liquid is not None
    assert (liquid.per_value, liquid.per_unit) == (Decimal(1), "мл")


@pytest.mark.parametrize("text", ["", "много", "500 мг+125 мг", "0 мг"])
def test_a_dosage_that_does_not_match_the_ingredients_is_unknown(text: str) -> None:
    assert parse_dosages(text, 1) == [None]
