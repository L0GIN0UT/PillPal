"""POST /v1/gtins/lookup, POST /v1/products/get and GET /v1/sources."""

from __future__ import annotations

import uuid
from decimal import Decimal

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from catalog.domain.gtin import check_digit
from tests.api.seed import Ingredient, Seed

GTIN = "04607012345677"
OTHER = "04607012345684"


def gtin14(body13: str) -> str:
    return body13 + check_digit(body13)


async def lookup(client: AsyncClient, gtin: str) -> dict[str, object]:
    response = await client.post("/v1/gtins/lookup", json={"gtin": gtin})
    assert response.status_code == 200, response.text
    body: dict[str, object] = response.json()
    return body


async def carded(seed: Seed) -> uuid.UUID:
    para = await seed.substance("para", "Paracetamol", "Парацетамол")
    comp = await seed.composition("c", [Ingredient(para, Decimal("500"), "mg")])
    return await seed.product(
        "testamol",
        "Testamol 500",
        market="ru",
        country="RU",
        composition=comp,
        registration_number="TST-000001",
        packages=[("20 tablets", [GTIN]), ("50 tablets", [OTHER])],
    )


async def test_lookup_found_returns_product_package_and_composition(
    client: AsyncClient, seed: Seed
) -> None:
    pid = await carded(seed)
    body = await lookup(client, GTIN)
    assert body["status"] == "found"
    product: dict[str, object] = body["product"]  # type: ignore[assignment]
    assert product["id"] == str(pid)
    assert product["name"] == "Testamol 500"
    assert product["market"] == "ru"
    assert product["source"] == "openfda_ndc"
    package: dict[str, object] = body["package"]  # type: ignore[assignment]
    assert package["description"] == "20 tablets"
    assert package["gtins"] == [GTIN]
    composition: dict[str, object] = body["composition"]  # type: ignore[assignment]
    ingredient = composition["ingredients"][0]  # type: ignore[index]
    assert ingredient["name_ru"] == "Парацетамол"
    assert Decimal(ingredient["strength_value"]) == 500


async def test_lookup_accepts_other_notations_of_the_same_number(
    client: AsyncClient, seed: Seed
) -> None:
    pid = await carded(seed)
    for typed in (GTIN[1:], f"{GTIN[1:5]} {GTIN[5:9]}-{GTIN[9:]}"):
        body = await lookup(client, typed)
        assert body["status"] == "found", typed
        assert body["product"]["id"] == str(pid)  # type: ignore[index]


async def test_lookup_unknown_for_a_valid_shareable_number_nobody_has(
    client: AsyncClient, seed: Seed
) -> None:
    await carded(seed)
    assert await lookup(client, gtin14("0460701234000")) == {
        "status": "unknown",
        "product": None,
        "package": None,
        "composition": None,
    }


async def test_lookup_restricted_never_touches_the_catalog(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    body = await lookup(client, gtin14("0200000000000"))
    assert body["status"] == "restricted"
    assert body["product"] is None


async def test_lookup_disputed_has_no_product_and_rejected_is_unknown(
    client: AsyncClient, seed: Seed
) -> None:
    pid = await carded(seed)
    await seed.decision(GTIN, "disputed")
    await seed.decision(OTHER, "rejected")
    disputed = await lookup(client, GTIN)
    assert disputed == {"status": "disputed", "product": None, "package": None, "composition": None}
    assert (await lookup(client, OTHER))["status"] == "unknown"
    assert pid  # the rows exist; the decision wins


async def test_lookup_prefers_the_admin_locked_product(client: AsyncClient, seed: Seed) -> None:
    await seed.product("first", "Aaa Product", packages=[("a", [GTIN])])
    locked = await seed.product("second", "Zzz Product", packages=[("z", [])])
    # a second source of the same number points at the locked product's package
    async with seed.engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO catalog.gtins (gtin, source, package_id, origin) "
                "SELECT :g, 'rxnorm', id, 'admin' FROM catalog.packages WHERE product_id = :p"
            ),
            {"g": GTIN, "p": locked},
        )
    await seed.decision(GTIN, "locked", locked)
    body = await lookup(client, GTIN)
    assert body["product"]["id"] == str(locked)  # type: ignore[index]


async def test_lookup_prefers_active_rows_then_source_over_consensus(
    client: AsyncClient, seed: Seed
) -> None:
    old = await seed.product("old", "Old Product", withdrawn=True, packages=[("o", [GTIN])])
    current = await seed.product("new", "New Product", packages=[("n", [])])
    async with seed.engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO catalog.gtins (gtin, source, package_id, origin) "
                "SELECT :g, 'consensus', id, 'consensus' FROM catalog.packages "
                "WHERE product_id = :p"
            ),
            {"g": GTIN, "p": current},
        )
    body = await lookup(client, GTIN)
    assert body["product"]["id"] == str(current)  # type: ignore[index]
    assert old


async def test_lookup_of_a_withdrawn_product_still_resolves(
    client: AsyncClient, seed: Seed
) -> None:
    await seed.product("old", "Old Product", withdrawn=True, packages=[("o", [GTIN])])
    body = await lookup(client, GTIN)
    assert body["status"] == "found"
    assert body["product"]["withdrawn"] is True  # type: ignore[index]


async def test_lookup_rejects_malformed_numbers_with_a_fixed_error(client: AsyncClient) -> None:
    for bad in ("123", "04607012345670", "abcdefgh", "٠٤٦٠٧٠١٢٣٤٥٦٧٧"):
        response = await client.post("/v1/gtins/lookup", json={"gtin": bad})
        assert response.status_code == 422, bad
        assert response.json()["error"]["code"] == "invalid_gtin"
        assert bad not in response.text
    for body in ({}, {"gtin": GTIN, "x": 1}, {"gtin": ""}, {"gtin": 4607012345677}):
        assert (await client.post("/v1/gtins/lookup", json=body)).status_code == 422


async def test_product_card_has_composition_packages_and_recalls(
    client: AsyncClient, seed: Seed
) -> None:
    pid = await carded(seed)
    await seed.recall("TST-000001", "SERIES-B")
    await seed.recall("TST-000001", "SERIES-A")
    await seed.recall("TST-999999", "OTHER")
    response = await client.post("/v1/products/get", json={"id": str(pid)})
    assert response.status_code == 200
    card = response.json()
    assert card["product"]["registration_number"] == "TST-000001"
    assert card["composition"]["complete"] is True
    assert card["composition"]["form_name_ru"] == "таблетки"
    assert [p["description"] for p in card["packages"]] == ["20 tablets", "50 tablets"]
    assert [p["gtins"] for p in card["packages"]] == [[GTIN], [OTHER]]
    assert [r["series"] for r in card["recalls"]] == ["SERIES-A", "SERIES-B"]
    assert response.headers["cache-control"] == "no-store"


async def test_product_card_of_a_product_without_composition(
    client: AsyncClient, seed: Seed
) -> None:
    pid = await seed.product("bare", "Bare", withdrawn=True)
    card = (await client.post("/v1/products/get", json={"id": str(pid)})).json()
    assert card["composition"] is None
    assert card["packages"] == []
    assert card["recalls"] == []
    assert card["product"]["withdrawn"] is True


async def test_unknown_product_is_404_and_bad_bodies_are_422(client: AsyncClient) -> None:
    missing = await client.post("/v1/products/get", json={"id": str(uuid.uuid4())})
    assert missing.status_code == 404
    assert missing.json()["error"]["code"] == "not_found"
    for body in ({}, {"id": "not-a-uuid"}, {"id": str(uuid.uuid4()), "x": 1}):
        assert (await client.post("/v1/products/get", json=body)).status_code == 422


async def test_sources_list_every_enabled_source_with_its_attribution(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    response = await client.get("/v1/sources")
    assert response.status_code == 200
    listed = {s["code"]: s for s in response.json()}
    async with engine.connect() as conn:
        enabled = {
            row.code: row
            for row in (
                await conn.execute(
                    text("SELECT code, attribution, license FROM catalog.sources WHERE enabled")
                )
            ).all()
        }
    assert set(listed) == set(enabled)
    assert "esklp" not in listed  # disabled until the owner decides (D1)
    for code, row in enabled.items():
        assert listed[code]["attribution"] == row.attribution
        assert set(listed[code]) == {"code", "name", "license", "attribution", "url"}
    assert list(listed) == sorted(listed)
    assert response.headers["cache-control"] == "public, max-age=3600"
