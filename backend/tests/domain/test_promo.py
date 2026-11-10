"""Promo code alphabet, normalisation and digest (ADR 0018 section 3). Pure, no fixtures."""

from __future__ import annotations

import random
import re

import pytest

from app.domain.promo import (
    ALPHABET,
    GROUP_SIZE,
    code_digest,
    generate_code,
    group_code,
    normalize_promo_code,
)

KEY = bytes(range(32))
OTHER_KEY = bytes(reversed(range(32)))


def test_the_alphabet_has_31_symbols_without_lookalikes() -> None:
    assert len(ALPHABET) == len(set(ALPHABET)) == 31
    assert not set("01OIL") & set(ALPHABET)
    assert ALPHABET == "23456789ABCDEFGHJKMNPQRSTUVWXYZ"


def test_a_generated_code_has_the_length_and_only_alphabet_symbols() -> None:
    code = generate_code(20)
    assert len(code) == 20
    assert set(code) <= set(ALPHABET)


def test_generated_codes_differ_and_use_the_whole_alphabet() -> None:
    codes = [generate_code(20) for _ in range(200)]
    assert len(set(codes)) == 200
    assert set("".join(codes)) == set(ALPHABET)


def test_generation_uses_the_given_random_source_for_every_symbol() -> None:
    first, second = random.Random(1), random.Random(1)
    assert generate_code(16, choice=first.choice) == generate_code(16, choice=second.choice)


def test_a_code_is_shown_in_groups_and_reads_back_to_itself() -> None:
    code = generate_code(20)
    shown = group_code(code)
    assert re.fullmatch(rf"(\w{{{GROUP_SIZE}}}-)+\w{{1,{GROUP_SIZE}}}", shown)
    assert normalize_promo_code(shown) == code


@pytest.mark.parametrize(
    ("typed", "expected"),
    [
        ("ABCD-2345-EFGH", "ABCD2345EFGH"),
        ("abcd 2345 efgh", "ABCD2345EFGH"),
        ("  abcd--2345  ", "ABCD2345"),
        ("2", "2"),
    ],
)
def test_spaces_hyphens_and_case_do_not_matter(typed: str, expected: str) -> None:
    assert normalize_promo_code(typed) == expected


@pytest.mark.parametrize(
    "typed",
    [
        "",
        "  - -  ",
        "ABCD0123",  # 0 and 1 are not in the alphabet
        "ABCDO",
        "ABCDI",
        "ABCDL",
        "ABCD_EFGH",
        "ABCD\tEFGH",  # only spaces and hyphens are separators
        "ABCD\nEFGH",
        "ABCD\u00a0EFGH",  # a no-break space is not a space
        "ABCD\u2011EFGH",  # nor is a non-breaking hyphen
        "ABCD\u0000",
    ],
)
def test_anything_outside_the_alphabet_is_invalid(typed: str) -> None:
    assert normalize_promo_code(typed) is None


@pytest.mark.parametrize(
    "typed",
    [
        "\u017f" * 4,  # long s: uppercases to S
        "AB\u0131D",  # dotless i: uppercases to I (also outside the alphabet)
        "\ufb01ABC",  # fi ligature: uppercases to two ASCII letters FI
        "\u212a" + "ABC",  # Kelvin sign: lowercases to k, uppercases to itself
        "\uff21BCD",  # fullwidth A
        "\u00dfABC",  # sharp s: uppercases to SS
        "\u0430BCD",  # Cyrillic a, a lookalike
    ],
)
def test_non_ascii_is_rejected_before_any_case_mapping(typed: str) -> None:
    assert normalize_promo_code(typed) is None


def test_the_digest_is_a_keyed_hash_of_the_normalised_code() -> None:
    digest = code_digest(KEY, "ABCD2345")
    assert re.fullmatch(r"[0-9a-f]{64}", digest)
    assert digest == code_digest(KEY, "ABCD2345")
    assert digest != code_digest(KEY, "ABCD2346")
    assert digest != code_digest(OTHER_KEY, "ABCD2345")  # a code of another region fails


def test_the_digest_matches_a_known_hmac_sha256() -> None:
    import hashlib
    import hmac

    expected = hmac.new(KEY, b"ABCD2345", hashlib.sha256).hexdigest()
    assert code_digest(KEY, "ABCD2345") == expected
