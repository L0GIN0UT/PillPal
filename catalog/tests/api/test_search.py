"""POST /v1/search: matching, ranking (D6), withdrawn rows, the GTIN path and input limits."""

from __future__ import annotations

import uuid
from decimal import Decimal
from typing import Any

from httpx import AsyncClient, Response

from catalog.domain.gtin import check_digit
from catalog.importers.ids import product_id
from tests.api.seed import Ingredient, Seed


def gtin14(body13: str) -> str:
    return body13 + check_digit(body13)


async def search(client: AsyncClient, q: str, **body: Any) -> Response:
    return await client.post("/v1/search", json={"q": q, "lang": "en", **body})


def names(response: Response) -> list[str]:
    assert response.status_code == 200, response.text
    return [r["name"] for r in response.json()["results"]]


async def paracetamol_catalog(seed: Seed) -> dict[str, uuid.UUID]:
    """A substance with a Russian name and products in three markets."""
    para = await seed.substance("para", "Paracetamol", "Парацетамол")
    comp = await seed.composition("para-500", [Ingredient(para, Decimal("500"), "mg")])
    return {
        "para": para,
        "testamol": await seed.product(
            "testamol", "Testamol 500", market="ru", country="RU", composition=comp
        ),
        "us": await seed.product("paracet", "Paracet Forte", market="us", composition=comp),
        "eu": await seed.product("eupara", "Europara", market="eu", country="DE", composition=comp),
    }


async def test_brand_prefix_finds_the_product_with_its_card_fields(
    client: AsyncClient, seed: Seed
) -> None:
    ids = await paracetamol_catalog(seed)
    response = await search(client, "testam")
    assert names(response) == ["Testamol 500"]
    body = response.json()
    assert body["mode"] == "text"
    assert body["results"][0] == {
        "kind": "product",
        "id": str(ids["testamol"]),
        "name": "Testamol 500",
        "market": "ru",
        "country": "RU",
        "manufacturer": "Example Pharma",
        "form": "tablet",
        "substances": ["Paracetamol"],
        "withdrawn": False,
    }


async def test_labels_follow_the_requested_language(client: AsyncClient, seed: Seed) -> None:
    await paracetamol_catalog(seed)
    result = (await search(client, "testam", lang="ru")).json()["results"][0]
    assert result["form"] == "таблетки"
    assert result["substances"] == ["Парацетамол"]


async def test_inn_finds_products_with_other_brand_names(client: AsyncClient, seed: Seed) -> None:
    await paracetamol_catalog(seed)
    assert set(names(await search(client, "paracetamol"))) == {
        "Testamol 500",
        "Paracet Forte",
        "Europara",
    }


async def test_a_typo_still_finds_the_substance_products(client: AsyncClient, seed: Seed) -> None:
    await paracetamol_catalog(seed)
    assert "Paracet Forte" in names(await search(client, "paracetmol"))


async def test_russian_inn_finds_foreign_products_through_substance_names(
    client: AsyncClient, seed: Seed
) -> None:
    await paracetamol_catalog(seed)
    found = names(await search(client, "парацетамол", lang="ru", market="ru"))
    assert found[0] == "Testamol 500"  # own market first
    assert set(found) == {"Testamol 500", "Paracet Forte", "Europara"}


async def test_yo_and_ye_are_the_same_letter(client: AsyncClient, seed: Seed) -> None:
    await seed.product("teplyj", "Тёплый тест", market="ru", country="RU")
    assert names(await search(client, "теплый", lang="ru")) == ["Тёплый тест"]
    assert names(await search(client, "тёплый", lang="ru")) == ["Тёплый тест"]


async def test_own_market_first_then_foreign_each_with_country(
    client: AsyncClient, seed: Seed
) -> None:
    await seed.product("a-us", "Testamol US", market="us", country="US")
    await seed.product("a-ru", "Testamol RU", market="ru", country="RU")
    await seed.product("a-eu", "Testamol EU", market="eu", country="DE")
    ru_first = await search(client, "testamol", market="ru")
    assert names(ru_first)[0] == "Testamol RU"
    assert {r["name"]: r["country"] for r in ru_first.json()["results"]} == {
        "Testamol RU": "RU",
        "Testamol US": "US",
        "Testamol EU": "DE",
    }
    assert names(await search(client, "testamol", market="eu"))[0] == "Testamol EU"
    # Without an own market there is no boost: ties are broken by id.
    expected = sorted(
        ["Testamol US", "Testamol RU", "Testamol EU"],
        key=lambda n: str(
            product_id(
                "openfda_ndc",
                {"Testamol US": "a-us", "Testamol RU": "a-ru", "Testamol EU": "a-eu"}[n],
            )
        ),
    )
    assert names(await search(client, "testamol")) == expected


async def test_withdrawn_products_sort_last_and_are_labelled(
    client: AsyncClient, seed: Seed
) -> None:
    await seed.product("w-ru", "Testamol Old", market="ru", withdrawn=True)
    await seed.product("w-us", "Testamol New", market="us")
    response = await search(client, "testamol", market="ru")
    assert names(response) == ["Testamol New", "Testamol Old"]
    assert [r["withdrawn"] for r in response.json()["results"]] == [False, True]


async def test_better_matches_rank_above_weaker_ones_in_the_same_market(
    client: AsyncClient, seed: Seed
) -> None:
    await seed.product("exact", "Testamol", market="us")
    await seed.product("typo", "Testamoll Forte Plus", market="us")
    assert names(await search(client, "testamol"))[0] == "Testamol"


async def test_ties_are_broken_by_id(client: AsyncClient, seed: Seed) -> None:
    await seed.product("t1", "Tiebreak", market="us")
    await seed.product("t2", "Tiebreak", market="us")
    await seed.product("t3", "Tiebreak", market="us")
    ids = [r["id"] for r in (await search(client, "tiebreak")).json()["results"]]
    assert ids == sorted(ids)
    assert len(ids) == 3


async def test_substance_kind_returns_substances_withdrawn_last(
    client: AsyncClient, seed: Seed
) -> None:
    await seed.substance("old", "Ibuprofen old", withdrawn=True, market="ru")
    await seed.substance("new", "Ibuprofen", "Ибупрофен", market="us")
    await seed.product("brand", "Ibuprofen brand")
    response = await search(client, "ibuprofen", kind="substance", market="ru")
    results = response.json()["results"]
    assert [r["kind"] for r in results] == ["substance", "substance"]
    assert [r["name"] for r in results] == ["Ibuprofen", "Ibuprofen old"]
    assert [r["withdrawn"] for r in results] == [False, True]
    ru = (await search(client, "ибупрофен", kind="substance", lang="ru")).json()["results"]
    assert [r["name"] for r in ru] == ["Ибупрофен"]


async def test_limit_is_capped_and_respected(client: AsyncClient, seed: Seed) -> None:
    for i in range(25):
        await seed.product(f"lim{i}", f"Limitol {i}")
    assert len(names(await search(client, "limitol"))) == 20  # default
    assert len(names(await search(client, "limitol", limit=3))) == 3
    assert len(names(await search(client, "limitol", limit=500))) == 20  # server cap


async def test_a_gtin_finds_its_product(client: AsyncClient, seed: Seed) -> None:
    code = gtin14("0460701234567")
    await seed.product("g", "Scanamol", packages=[("20 tablets", [code])])
    for typed in (code, code[1:], f"{code[1:5]} {code[5:]}"):
        response = await search(client, typed)
        assert names(response) == ["Scanamol"], typed
        assert response.json()["mode"] == "gtin"


async def test_gtin_path_answers_empty_for_unknown_invalid_and_restricted(
    client: AsyncClient, seed: Seed
) -> None:
    await seed.product("g", "Scanamol", packages=[("20", [gtin14("0460701234567")])])
    unknown = gtin14("0460701234000")
    bad_digit = "04607012345670" if gtin14("0460701234567")[-1] != "0" else "04607012345671"
    restricted = gtin14("0200000000000")
    for q in (unknown, bad_digit, restricted):
        response = await search(client, q)
        assert response.json() == {"mode": "gtin", "results": []}, q


async def test_punctuation_and_query_syntax_are_data_not_syntax(
    client: AsyncClient, seed: Seed
) -> None:
    await seed.product("p", "Testamol")
    for q in ("!!", "a & | ( !", "'; DROP TABLE catalog.products; --", "test:* & x", "\\\\"):
        response = await search(client, q)
        assert response.status_code == 200, q
    assert names(await search(client, "testamol")) == ["Testamol"]  # table still there


async def test_invalid_requests_are_422_without_echoing_the_input(client: AsyncClient) -> None:
    secret = "sentinel-search-string"
    bad_bodies: list[dict[str, Any]] = [
        {"q": "a", "lang": "en"},
        {"q": "   ", "lang": "en"},
        {"q": "x" * 101, "lang": "en"},
        {"q": secret, "lang": "xx"},
        {"q": secret},
        {"q": secret, "lang": "en", "market": "mars"},
        {"q": secret, "lang": "en", "kind": "analog"},
        {"q": secret, "lang": "en", "limit": 0},
        {"q": secret, "lang": "en", "extra": 1},
        {"lang": "en"},
    ]
    for body in bad_bodies:
        response = await client.post("/v1/search", json=body)
        assert response.status_code == 422, body
        assert response.json()["error"]["code"] == "validation_error"
        assert secret not in response.text


async def test_the_query_is_trimmed_before_its_length_is_checked(
    client: AsyncClient, seed: Seed
) -> None:
    await seed.product("p", "Testamol")
    assert names(await search(client, "  testamol  ")) == ["Testamol"]
    assert (await search(client, " " + "x" * 100 + " ")).status_code == 200
