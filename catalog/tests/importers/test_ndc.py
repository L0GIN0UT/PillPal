"""NDC to GTIN, package counts and strengths as openFDA and RxNorm print them (pure unit tests)."""

from __future__ import annotations

from decimal import Decimal

import pytest

from catalog.domain.gtin import normalize
from catalog.importers.ndc import package_count, package_gtin14
from catalog.importers.openfda_ndc import PRODUCT_NDC
from catalog.importers.strength import Strength, parse_strength


@pytest.mark.parametrize(
    ("ndc", "gtin14"),
    [
        ("0002-3227-30", "00300023227300"),  # 4-4-2
        ("50580-506-02", "00350580506028"),  # 5-3-2
        ("00093-7146-1", "00300093714618"),  # 5-4-1
        ("99999-111-22", "00399999111225"),
        ("9999-1111-22", "00399991111223"),
        ("99999-1112-3", "00399999111232"),
    ],
)
def test_every_ndc_configuration_gives_a_gtin14_with_a_valid_check_digit(
    ndc: str, gtin14: str
) -> None:
    assert package_gtin14(ndc) == gtin14
    assert normalize(gtin14).gtin14 == gtin14  # the shared module accepts the check digit


@pytest.mark.parametrize(
    "bad",
    [
        "",
        "0002-3227",  # a product NDC has no package segment
        "12345-678-9",  # 9 digits
        "12345-6789-01",  # 11-digit billing form
        "123456789-0",  # no known configuration
        "1234-567-890",
        "12345-678-9x",
        "12345 678 90",
        "١٢٣٤٥-٦٧٨-٩٠",  # non-ASCII digits
        "12345-678-90\n",
    ],
)
def test_other_shapes_are_not_package_ndcs(bad: str) -> None:
    assert package_gtin14(bad) is None


@pytest.mark.parametrize(
    ("description", "expected"),
    [
        ("100 TABLET in 1 BOTTLE", (Decimal(100), "tablet")),
        ("30 TABLET, FILM COATED in 1 BOTTLE (12345-678-90)", (Decimal(30), "tablet, film coated")),
        ("1 BOTTLE in 1 CARTON (1-2-3) > 100 TABLET in 1 BOTTLE", (Decimal(100), "tablet")),
        ("2 BLISTER PACK in 1 CARTON > 10 TABLET in 1 BLISTER PACK", (Decimal(20), "tablet")),
        ("1,000 TABLET in 1 BOTTLE", (Decimal(1000), "tablet")),
        ("473 mL in 1 BOTTLE", (Decimal(473), "ml")),
        ("2.5 mL in 1 VIAL", (Decimal("2.5"), "ml")),
    ],
)
def test_a_package_count_is_parsed_from_the_description(
    description: str, expected: tuple[Decimal, str]
) -> None:
    assert package_count(description) == expected


@pytest.mark.parametrize(
    "description",
    [
        None,
        "",
        "KIT",
        "TABLET in 1 BOTTLE",  # no number
        "0 TABLET in 1 BOTTLE",  # not positive
        "2 BLISTER PACK in 1 CARTON > 10 TABLET in 1 TRAY",  # chain does not connect
        "1 BOTTLE in 1 CARTON > 100 TABLET in 1 BOTTLE > x",
        "99999999999999999999 TABLET in 1 BOTTLE",  # absurd
        "1" + "0" * 5000 + " TABLET in 1 BOTTLE",
    ],
)
def test_an_unparseable_count_is_null(description: str | None) -> None:
    assert package_count(description) is None


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("500 mg/1", Strength(Decimal(500), "mg")),
        ("250 mg/5 mL", Strength(Decimal(250), "mg", Decimal(5), "mL")),
        ("5 mg/mL", Strength(Decimal(5), "mg", Decimal(1), "mL")),
        ("0.5 mg/mL", Strength(Decimal("0.5"), "mg", Decimal(1), "mL")),
        ("1000 [USP'U]/1", Strength(Decimal(1000), "[USP'U]")),
        ("500 MG", Strength(Decimal(500), "MG")),
        ("5 MG/ML", Strength(Decimal(5), "MG", Decimal(1), "ML")),
        ("1,000 mg/1", Strength(Decimal(1000), "mg")),
    ],
)
def test_strengths_are_parsed(text: str, expected: Strength) -> None:
    assert parse_strength(text) == expected


@pytest.mark.parametrize("text", ["", "mg/1", "500", "0 mg/1", "-5 mg/1", "abc mg/1", "5 mg/0 mL"])
def test_an_unparseable_or_non_positive_strength_is_none(text: str) -> None:
    assert parse_strength(text) is None


def test_an_overlong_strength_is_none() -> None:
    assert parse_strength("5 " + "m" * 200 + "/1") is None
    assert parse_strength("5 mg/" + "9" * 300) is None


@pytest.mark.parametrize("ndc", ["0002-3227", "99999-111", "99999-1112"])
def test_product_ndc_shapes_are_4_4_5_3_and_5_4(ndc: str) -> None:
    assert PRODUCT_NDC.fullmatch(ndc) is not None


@pytest.mark.parametrize("ndc", ["123-4567", "1234-567", "123456-78", "1234-56789", "12345-67"])
def test_other_product_ndc_shapes_are_rejected(ndc: str) -> None:
    assert PRODUCT_NDC.fullmatch(ndc) is None
