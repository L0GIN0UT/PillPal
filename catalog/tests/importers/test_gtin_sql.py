"""The SQL functions behind the gtins CHECK implement the 4.2 classification (docs/spec/gtin.md
section 3) from gtin14 only. The shared vectors run through them so SQL cannot drift."""

from __future__ import annotations

import json
import uuid
from typing import Any

import pytest
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import CATALOG_DIR

VECTORS = CATALOG_DIR.parent / "spec" / "gtin-vectors" / "normalize.json"
MIN_CASES = 30


def _classified_cases() -> list[Any]:
    cases = json.loads(VECTORS.read_text(encoding="utf-8"))["cases"]
    picked: dict[str, str] = {}
    for case in cases:
        expected = case["expected"]
        if case["op"] == "normalize" and "gtin14" in expected:
            picked[expected["gtin14"]] = expected["classification"]
    return [pytest.param(g, c, id=f"{g}-{c}") for g, c in sorted(picked.items())]


CASES = _classified_cases()


def test_the_vectors_are_loaded() -> None:
    assert len(CASES) >= MIN_CASES
    assert {case.values[1] for case in CASES} == {"shareable", "restricted"}


async def _flag(engine: AsyncEngine, function: str, value: str) -> bool:
    async with engine.connect() as conn:
        result = await conn.execute(text(f"SELECT catalog.{function}(:g)"), {"g": value})
        return bool(result.scalar())


@pytest.mark.parametrize(("gtin14", "classification"), CASES)
async def test_sql_classification_matches_the_vectors(
    engine: AsyncEngine, gtin14: str, classification: str
) -> None:
    assert await _flag(engine, "gtin_check_digit_ok", gtin14)
    shareable = await _flag(engine, "gtin_is_shareable", gtin14)
    assert shareable == (classification == "shareable")


@pytest.mark.parametrize(("gtin14", "classification"), CASES)
async def test_sql_rejects_a_wrong_check_digit(
    engine: AsyncEngine, gtin14: str, classification: str
) -> None:
    del classification
    wrong = gtin14[:13] + str((int(gtin14[13]) + 1) % 10)
    assert not await _flag(engine, "gtin_check_digit_ok", wrong)


@pytest.mark.parametrize(
    "value",
    ["", "123", "4607012345677", "046070123456777", "0460701234567a", "٠٤٦٠٧٠١٢٣٤٥٦٧٧"],
)
async def test_sql_functions_reject_malformed_text(engine: AsyncEngine, value: str) -> None:
    assert not await _flag(engine, "gtin_check_digit_ok", value)
    assert not await _flag(engine, "gtin_is_shareable", value)


async def _insert_gtin(engine: AsyncEngine, gtin: str) -> None:
    run, product, package = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO catalog.import_runs (id, source, snapshot_sha256, status, finished_at)"
                " VALUES (:r, 'openfda_ndc', :h, 'succeeded', now())"
            ),
            {"r": run, "h": "d" * 64},
        )
        await conn.execute(
            text(
                "INSERT INTO catalog.products (id, source, source_key, market, brand_name, "
                "last_run_id) VALUES (:p, 'openfda_ndc', 'p', 'us', 'Testamol 500', :r)"
            ),
            {"p": product, "r": run},
        )
        await conn.execute(
            text(
                "INSERT INTO catalog.packages (id, product_id, source, source_key, last_run_id) "
                "VALUES (:k, :p, 'openfda_ndc', 'k', :r)"
            ),
            {"k": package, "p": product, "r": run},
        )
        await conn.execute(
            text(
                "INSERT INTO catalog.gtins (gtin, source, package_id, origin) "
                "VALUES (:g, 'openfda_ndc', :k, 'source')"
            ),
            {"g": gtin, "k": package},
        )


@pytest.mark.parametrize(
    "gtin",
    [
        "00200000000004",  # prefix 020: restricted distribution
        "90614141000411",  # indicator digit 9: variable measure
        "00000002345673",  # RCN-8
        "04607012345678",  # wrong check digit
        "4607012345677",  # 13 digits
        "0460701234567x",  # not digits
    ],
)
async def test_the_check_rejects_restricted_and_invalid_numbers_even_by_direct_insert(
    engine: AsyncEngine, clean_catalog: None, gtin: str
) -> None:
    with pytest.raises(IntegrityError, match="gtins_valid_shareable"):
        await _insert_gtin(engine, gtin)


async def test_a_valid_shareable_gtin_is_accepted(engine: AsyncEngine, clean_catalog: None) -> None:
    await _insert_gtin(engine, "04607012345677")
