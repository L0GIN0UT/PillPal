"""Regression tests for the review of PR 39: cheap-query DoS, locked GTINs, no-store everywhere,
restricted numbers never reaching the catalog, check constraints."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine

from catalog.domain.gtin import check_digit
from tests.api.seed import Seed
from tests.api.test_public_guards import app_client

GTIN = "04607012345677"
RESTRICTED = "0200000000000" + check_digit("0200000000000")


async def found(client: AsyncClient, q: str) -> list[str]:
    response = await client.post("/v1/search", json={"q": q, "lang": "en"})
    assert response.status_code == 200, q
    return [r["name"] for r in response.json()["results"]]


async def test_one_letter_queries_do_not_become_prefix_scans(
    client: AsyncClient, seed: Seed
) -> None:
    await seed.product("x", "Xanthol")
    await seed.product("a", "A Bravo")
    # fewer than two letters or digits after normalisation: nothing to look for
    for q in ("x.", "a-", ".a.", "-x-"):
        assert await found(client, q) == [], q
    # "a b" is two letters, but the last token is not expanded to a prefix and has no typo path
    assert await found(client, "a b") == []
    assert await found(client, "a bravo") == ["A Bravo"]
    assert await found(client, "xa") == ["Xanthol"]


async def test_a_locked_gtin_answers_with_the_locked_product_even_without_its_package(
    client: AsyncClient, seed: Seed
) -> None:
    await seed.product("other", "Other Product", packages=[("o", [GTIN])])
    locked = await seed.product("locked", "Locked Product")  # no package row at all
    await seed.decision(GTIN, "locked", locked)
    body = (await client.post("/v1/gtins/lookup", json={"gtin": GTIN})).json()
    assert body["status"] == "found"
    assert body["product"]["id"] == str(locked)
    assert body["package"] is None


@pytest.mark.parametrize("path", ["/v1/search", "/v1/gtins/lookup", "/v1/products/get"])
async def test_every_answer_of_a_lookup_route_is_no_store(
    client: AsyncClient, seed: Seed, path: str
) -> None:
    good: dict[str, Any] = {
        "/v1/search": {"q": "testamol", "lang": "en"},
        "/v1/gtins/lookup": {"gtin": GTIN},
        "/v1/products/get": {"id": str(uuid.uuid4())},  # 404
    }
    bad: dict[str, Any] = {"x": 1}  # 422
    cases = [
        (good[path], {}),
        (bad, {}),
        (good[path], {"Authorization": "Bearer x"}),  # 400
        ({"q": "x" * 5000}, {}),  # 413
    ]
    for body, headers in cases:
        response = await client.post(path, json=body, headers=headers)
        assert response.status_code in (200, 400, 404, 413, 422), response.text
        assert response.headers["cache-control"] == "no-store", response.status_code


async def test_rate_limited_answers_are_no_store_and_sources_keep_their_cache_header(
    clean_redis: None,
) -> None:
    async with app_client(rate_limit_ip_max=1) as (client, _):
        await client.post("/v1/search", json={"q": "testamol", "lang": "en"})
        blocked = await client.post("/v1/search", json={"q": "testamol", "lang": "en"})
    assert blocked.status_code == 429
    assert blocked.headers["cache-control"] == "no-store"
    async with app_client() as (client, _):
        sources = await client.get("/v1/sources")
        health = await client.get("/healthz")
    assert sources.headers["cache-control"] == "public, max-age=3600"
    assert "cache-control" not in health.headers


async def test_restricted_numbers_never_reach_a_catalog_query(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def forbidden(*_: object, **__: object) -> object:
        raise AssertionError("a restricted number reached the catalog")

    monkeypatch.setattr("catalog.services.cards.resolve_gtin", forbidden)
    monkeypatch.setattr("catalog.services.search.find_product_by_gtin", forbidden)
    lookup = await client.post("/v1/gtins/lookup", json={"gtin": RESTRICTED})
    assert lookup.status_code == 200
    assert lookup.json()["status"] == "restricted"
    searched = await client.post("/v1/search", json={"q": RESTRICTED, "lang": "en"})
    assert searched.status_code == 200
    assert searched.json() == {"mode": "gtin", "results": []}


async def test_a_found_package_without_a_product_card_degrades_to_unknown(
    client: AsyncClient, seed: Seed, monkeypatch: pytest.MonkeyPatch
) -> None:
    await seed.product("p", "Testamol", packages=[("20", [GTIN])])

    async def no_card(*_: object, **__: object) -> None:
        return None

    monkeypatch.setattr("catalog.services.cards.product_card", no_card)
    body = (await client.post("/v1/gtins/lookup", json={"gtin": GTIN})).json()
    assert body["status"] == "unknown"


async def test_decision_reason_codes_are_short_machine_codes(engine: AsyncEngine) -> None:
    for reason in ("Free text with a name", "x" * 65, "UPPER"):
        async with engine.begin() as conn:
            with pytest.raises(IntegrityError):
                await conn.execute(
                    text(
                        "INSERT INTO catalog.gtin_link_decisions "
                        "(gtin, status, decided_by, reason_code) "
                        "VALUES (:g, 'disputed', 'auto', :r)"
                    ),
                    {"g": GTIN, "r": reason},
                )
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO catalog.gtin_link_decisions (gtin, status, decided_by, reason_code) "
                "VALUES (:g, 'disputed', 'auto', 'competing_links')"
            ),
            {"g": GTIN},
        )
        await conn.execute(text("DELETE FROM catalog.gtin_link_decisions"))


def test_package_and_composition_ids_are_redacted_too() -> None:
    from catalog.observability import redact_sensitive

    keys = ("package_id", "catalog_package_id", "catalog_composition_id")
    cleaned = redact_sensitive(None, "info", dict.fromkeys(keys, "v"))
    assert set(cleaned.values()) == {"[redacted]"}
