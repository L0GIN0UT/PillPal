"""Medication catalog references over REST (4.6, ADR 0015 §4): fields, consent, erasure."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.grace_helpers import request_deletion, run_erase_job
from tests.helpers import User, create_medication, register
from tests.test_account_privacy import _rows_mentioning

GTIN = "04600000000011"
OTHER_GTIN = "04600000000028"
PRODUCT = "5b0f4a52-8e1b-4f60-9d3b-0a2f3c9d1e11"
OTHER_PRODUCT = "5b0f4a52-8e1b-4f60-9d3b-0a2f3c9d1e22"
PACKAGE = "5b0f4a52-8e1b-4f60-9d3b-0a2f3c9d1e33"
COMPOSITION = "5b0f4a52-8e1b-4f60-9d3b-0a2f3c9d1e44"
INGREDIENT = "5b0f4a52-8e1b-4f60-9d3b-0a2f3c9d1e55"

REFS: dict[str, Any] = {
    "catalog_product_id": PRODUCT,
    "catalog_package_id": PACKAGE,
    "catalog_composition_id": COMPOSITION,
    "gtin": GTIN,
    "manual_ingredients": [
        {"substance_id": INGREDIENT, "name": "Парацетамол", "strength_text": "500 мг"},
        {"name": "Synthetic extract"},
    ],
}


async def patch(client: AsyncClient, user: User, med_id: str, body: dict[str, Any]) -> Any:
    return await client.patch(f"/v1/medications/{med_id}", json=body, headers=user.headers)


async def row(engine: AsyncEngine, med_id: str) -> Any:
    async with engine.connect() as conn:
        found = await conn.execute(text("SELECT * FROM medications WHERE id = :i"), {"i": med_id})
        return found.one()


# --- round trip ------------------------------------------------------------------------


async def test_references_round_trip_through_create_and_get(client: AsyncClient) -> None:
    user = await register(client)
    created = await create_medication(client, user, **REFS)
    got = await client.get(f"/v1/medications/{created['id']}", headers=user.headers)
    for body in (created, got.json()):
        assert body["catalog_product_id"] == PRODUCT
        assert body["catalog_package_id"] == PACKAGE
        assert body["catalog_composition_id"] == COMPOSITION
        assert body["gtin"] == GTIN
        assert body["manual_ingredients"] == [
            {"substance_id": INGREDIENT, "name": "Парацетамол", "strength_text": "500 мг"},
            {"substance_id": None, "name": "Synthetic extract", "strength_text": None},
        ]
        assert body["gtin_link_shared"] is False
        assert body["gtin_link_consent_version"] is None
        assert body["gtin_link_consented_at"] is None


async def test_a_medication_without_references_has_them_null(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    assert med["gtin"] is None
    assert med["manual_ingredients"] is None
    assert med["catalog_product_id"] is None


async def test_the_list_returns_the_references_too(client: AsyncClient) -> None:
    user = await register(client)
    await create_medication(client, user, **REFS)
    resp = await client.get(
        f"/v1/profiles/{user.self_profile_id}/medications", headers=user.headers
    )
    assert resp.json()["items"][0]["gtin"] == GTIN


# --- PATCH is partial ------------------------------------------------------------------


async def test_patch_of_other_fields_keeps_the_references(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user, **REFS)
    resp = await patch(client, user, med["id"], {"notes": "changed"})
    assert resp.status_code == 200
    assert resp.json()["notes"] == "changed"
    assert resp.json()["gtin"] == GTIN
    assert resp.json()["catalog_product_id"] == PRODUCT
    assert len(resp.json()["manual_ingredients"]) == 2


async def test_patch_with_null_clears_one_reference(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user, **REFS)
    resp = await patch(client, user, med["id"], {"catalog_package_id": None})
    assert resp.json()["catalog_package_id"] is None
    assert resp.json()["catalog_product_id"] == PRODUCT


async def test_patch_sets_references_on_a_plain_medication(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    resp = await patch(client, user, med["id"], {"gtin": GTIN, "catalog_product_id": PRODUCT})
    assert resp.json()["gtin"] == GTIN


# --- validation (422) ------------------------------------------------------------------


@pytest.mark.parametrize(
    "gtin", ["123", "4600000000001", "046000000000111", "0460000000001a", "0460000000001 ", ""]
)
async def test_a_gtin_must_be_fourteen_digits(client: AsyncClient, gtin: str) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    assert (await patch(client, user, med["id"], {"gtin": gtin})).status_code == 422


async def test_a_restricted_gtin_may_be_kept_privately(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user, gtin="02000000000011")
    assert med["gtin"] == "02000000000011"


async def test_more_than_ten_manual_ingredients_are_refused(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    items = [{"name": f"Synthetic {i}"} for i in range(11)]
    assert (await patch(client, user, med["id"], {"manual_ingredients": items})).status_code == 422
    ok = await patch(client, user, med["id"], {"manual_ingredients": items[:10]})
    assert ok.status_code == 200


@pytest.mark.parametrize(
    "item",
    [
        {"name": ""},
        {"name": "x" * 101},
        {"name": "Ok", "strength_text": "x" * 51},
        {"name": "Ok", "substance_id": "not-a-uuid"},
        {"name": "Ok", "extra": 1},
        {"strength_text": "5 mg"},
    ],
)
async def test_a_manual_ingredient_is_validated(client: AsyncClient, item: dict[str, Any]) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    resp = await patch(client, user, med["id"], {"manual_ingredients": [item]})
    assert resp.status_code == 422


async def test_the_flag_is_a_strict_boolean_and_not_nullable(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user, gtin=GTIN, catalog_product_id=PRODUCT)
    for value in (None, "yes", 1):
        resp = await patch(
            client, user, med["id"], {"gtin_link_shared": value, "gtin_link_consent_version": 1}
        )
        assert resp.status_code == 422


async def test_server_fields_cannot_be_set_over_rest(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    resp = await patch(client, user, med["id"], {"gtin_link_consented_at": "2026-11-01T00:00:00Z"})
    assert resp.status_code == 422


# --- consent over REST -----------------------------------------------------------------


async def test_consent_is_recorded_with_the_version_and_a_server_time(
    client: AsyncClient,
) -> None:
    user = await register(client)
    med = await create_medication(
        client,
        user,
        gtin=GTIN,
        catalog_product_id=PRODUCT,
        gtin_link_shared=True,
        gtin_link_consent_version=1,
    )
    assert med["gtin_link_shared"] is True
    assert med["gtin_link_consent_version"] == 1
    assert med["gtin_link_consented_at"] is not None


async def test_an_unknown_consent_version_is_a_422(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user, gtin=GTIN, catalog_product_id=PRODUCT)
    resp = await patch(
        client, user, med["id"], {"gtin_link_shared": True, "gtin_link_consent_version": 99}
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "unsupported_consent_version"


async def test_the_flag_without_a_version_is_a_422(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user, gtin=GTIN, catalog_product_id=PRODUCT)
    resp = await patch(client, user, med["id"], {"gtin_link_shared": True})
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "consent_version_required"


async def test_the_flag_needs_a_gtin_and_a_product(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(client, user, gtin=GTIN)
    resp = await patch(
        client, user, med["id"], {"gtin_link_shared": True, "gtin_link_consent_version": 1}
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "gtin_link_needs_gtin_and_product"


async def test_relinking_over_rest_resets_the_consent(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(
        client,
        user,
        gtin=GTIN,
        catalog_product_id=PRODUCT,
        gtin_link_shared=True,
        gtin_link_consent_version=1,
    )
    resp = await patch(client, user, med["id"], {"catalog_product_id": OTHER_PRODUCT})
    assert resp.json()["gtin_link_shared"] is False
    assert resp.json()["gtin_link_consent_version"] is None
    assert resp.json()["gtin_link_consented_at"] is None


async def test_patching_other_fields_keeps_the_consent(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(
        client,
        user,
        gtin=GTIN,
        catalog_product_id=PRODUCT,
        gtin_link_shared=True,
        gtin_link_consent_version=1,
    )
    resp = await patch(client, user, med["id"], {"notes": "x"})
    assert resp.json()["gtin_link_shared"] is True
    assert resp.json()["gtin_link_consented_at"] == med["gtin_link_consented_at"]


async def test_withdrawing_consent_clears_the_record(client: AsyncClient) -> None:
    user = await register(client)
    med = await create_medication(
        client,
        user,
        gtin=GTIN,
        catalog_product_id=PRODUCT,
        gtin_link_shared=True,
        gtin_link_consent_version=1,
    )
    resp = await patch(client, user, med["id"], {"gtin_link_shared": False})
    assert resp.json()["gtin_link_shared"] is False
    assert resp.json()["gtin_link_consent_version"] is None


# --- authentication and ownership ------------------------------------------------------


async def test_references_need_authentication(client: AsyncClient) -> None:
    resp = await client.patch(f"/v1/medications/{uuid.uuid4()}", json={"gtin": GTIN})
    assert resp.status_code == 401


async def test_another_users_medication_is_not_found(client: AsyncClient) -> None:
    owner, other = await register(client), await register(client)
    med = await create_medication(client, owner, **REFS)
    assert (await patch(client, other, med["id"], {"gtin": OTHER_GTIN})).status_code == 404
    assert (
        await client.get(f"/v1/medications/{med['id']}", headers=other.headers)
    ).status_code == 404
    assert (await patch(client, owner, med["id"], {"notes": "n"})).json()["gtin"] == GTIN


# --- schema (CHECK constraints) --------------------------------------------------------


async def _update(engine: AsyncEngine, med_id: str, sql: str) -> None:
    async with engine.begin() as conn:
        await conn.execute(text(f"UPDATE medications SET {sql} WHERE id = :i"), {"i": med_id})  # noqa: S608


@pytest.mark.parametrize(
    ("sql", "constraint"),
    [
        ("gtin = '123'", "gtin_format"),
        (
            "gtin_link_shared = true, gtin_link_consent_version = 1, "
            "gtin_link_consented_at = now(), "
            "gtin = NULL",
            "gtin_link_needs_refs",
        ),
        (
            "gtin_link_shared = true, gtin_link_consent_version = 1, "
            "gtin_link_consented_at = now(), "
            "catalog_product_id = NULL",
            "gtin_link_needs_refs",
        ),
        ("gtin_link_consent_version = 1", "gtin_link_consent_pair"),
        ("gtin_link_shared = true", "gtin_link_consent_pair"),
        ("manual_ingredients = '{}'::jsonb", "manual_ingredients"),
        ("manual_ingredients = 'null'::jsonb", "manual_ingredients"),
        (
            'manual_ingredients = (SELECT jsonb_agg(\'{"name": "x"}\'::jsonb) '
            "FROM generate_series(1, 11))",
            "manual_ingredients",
        ),
    ],
)
async def test_the_database_enforces_the_reference_rules(
    client: AsyncClient, engine: AsyncEngine, sql: str, constraint: str
) -> None:
    user = await register(client)
    med = await create_medication(client, user, gtin=GTIN, catalog_product_id=PRODUCT)
    with pytest.raises(IntegrityError, match=constraint):
        await _update(engine, med["id"], sql)


async def test_the_database_refuses_consent_on_a_tombstone(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    med = await create_medication(
        client,
        user,
        gtin=GTIN,
        catalog_product_id=PRODUCT,
        gtin_link_shared=True,
        gtin_link_consent_version=1,
    )
    # A live flag on a tombstone: PostgreSQL reports the first failing CHECK by name, and
    # ``gtin_link_live`` sorts before ``tombstone_erased``.
    erase = (
        "name = NULL, form = NULL, strength_text = NULL, notes = NULL, stock_count = NULL, "
        "stock_unit = NULL, low_stock_days = NULL, stock_set_at = NULL, deleted_at = now()"
    )
    with pytest.raises(IntegrityError, match="gtin_link_live"):
        await _update(engine, med["id"], erase)


@pytest.mark.parametrize(
    "leftover",
    [
        "gtin = '04600000000011'",
        "catalog_product_id = gen_random_uuid()",
        "catalog_package_id = gen_random_uuid()",
        "catalog_composition_id = gen_random_uuid()",
        "manual_ingredients = '[]'::jsonb",
    ],
)
async def test_the_database_refuses_references_on_a_tombstone(
    client: AsyncClient, engine: AsyncEngine, leftover: str
) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    erase = (
        "name = NULL, form = NULL, strength_text = NULL, notes = NULL, stock_unit = NULL, "
        "low_stock_days = NULL, deleted_at = now(), " + leftover
    )
    with pytest.raises(IntegrityError, match="tombstone_erased"):
        await _update(engine, med["id"], erase)


# --- erasure ---------------------------------------------------------------------------


async def test_deleting_a_medication_erases_references_and_consent(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    med = await create_medication(
        client,
        user,
        **REFS,
        gtin_link_shared=True,
        gtin_link_consent_version=1,
    )
    resp = await client.delete(f"/v1/medications/{med['id']}", headers=user.headers)
    assert resp.status_code == 204
    found = await row(engine, med["id"])
    assert found.deleted_at is not None
    assert found.gtin is None
    assert found.catalog_product_id is None
    assert found.catalog_package_id is None
    assert found.catalog_composition_id is None
    assert found.manual_ingredients is None
    assert found.gtin_link_shared is False
    assert found.gtin_link_consent_version is None
    assert found.gtin_link_consented_at is None


async def test_deleting_a_profile_erases_the_references_of_its_medications(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    pid = str(uuid.uuid4())
    resp = await client.post(
        "/v1/profiles",
        json={"id": pid, "display_name": "Synthetic Ward", "timezone": "UTC"},
        headers=user.headers,
    )
    assert resp.status_code == 201, resp.text
    med = await create_medication(
        client,
        user,
        profile_id=pid,
        **REFS,
        gtin_link_shared=True,
        gtin_link_consent_version=1,
    )
    assert (await client.delete(f"/v1/profiles/{pid}", headers=user.headers)).status_code == 204
    found = await row(engine, med["id"])
    assert found.deleted_at is not None
    assert (found.gtin, found.manual_ingredients, found.gtin_link_shared) == (None, None, False)
    assert found.gtin_link_consented_at is None


NEEDLES = [GTIN, PRODUCT, PACKAGE, COMPOSITION, INGREDIENT, "Парацетамол", "Synthetic extract"]


async def test_no_table_mentions_the_references_after_a_medication_is_deleted(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    med = await create_medication(
        client, user, **REFS, gtin_link_shared=True, gtin_link_consent_version=1
    )
    assert await _rows_mentioning(engine, NEEDLES)
    await client.delete(f"/v1/medications/{med['id']}", headers=user.headers)
    assert await _rows_mentioning(engine, NEEDLES) == {}


async def test_no_table_mentions_the_references_after_the_account_is_erased(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await create_medication(
        client, user, **REFS, gtin_link_shared=True, gtin_link_consent_version=1
    )
    assert await _rows_mentioning(engine, NEEDLES)
    assert (await request_deletion(client, user)).status_code == 204
    report = await run_erase_job(client, datetime.now(UTC) + timedelta(days=31))
    assert report.erased == 1
    assert await _rows_mentioning(engine, NEEDLES) == {}
