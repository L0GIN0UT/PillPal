"""``POST /v1/me/purchases`` (ADR 0018 section 6): access, claim, replay and dedup."""

from __future__ import annotations

import asyncio
import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from tests.grace_helpers import count, scalar
from tests.helpers import User, register
from tests.payments_helpers import (
    PRODUCT_ID,
    Chain,
)
from tests.purchase_helpers import (
    INVALID,
    URL,
    account_token,
    buy,
    claim,
    signed,
)

pytestmark = pytest.mark.usefixtures("payments_on")


def uid(user: User) -> uuid.UUID:
    return uuid.UUID(user.id)


# --- access --------------------------------------------------------------------------------------


async def test_it_needs_a_signed_in_account(client: AsyncClient) -> None:
    resp = await client.post(URL, json={"store": "app_store", "signed_transaction": "x"})
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "unauthorized"


async def test_the_flag_off_answers_403(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    user = await register(client)
    monkeypatch.setattr(settings, "feature_payments", False)
    resp = await claim(client, user, "x")
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "feature_disabled"


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"store": "app_store"},
        {"store": "app_store", "signed_transaction": ""},
        {"store": "app_store", "purchase_token": "t"},
        {"store": "rustore", "signed_transaction": "t"},
        {"store": "rustore", "purchase_token": "t", "signed_transaction": "t"},
        {"store": "bank", "purchase_token": "t"},
        {"store": "app_store", "signed_transaction": "t", "extra": 1},
        {"store": "app_store", "signed_transaction": 5},
    ],
)
async def test_a_malformed_body_is_a_422(client: AsyncClient, body: dict[str, Any]) -> None:
    user = await register(client)
    resp = await client.post(URL, json=body, headers=user.headers)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "validation_error"


# --- the claim -----------------------------------------------------------------------------------


async def test_a_verified_purchase_grants_both_kinds(
    client: AsyncClient, apple_chain: Chain, engine: AsyncEngine
) -> None:
    user = await register(client)
    resp = await buy(client, apple_chain, user)
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert (body["ads_removed"], body["limits_lifted"]) == (True, True)
    assert {item["kind"] for item in body["items"]} == {"ads_removed", "limits_lifted"}
    assert {item["source"] for item in body["items"]} == {"purchase"}
    assert all(item["expires_at"] is None for item in body["items"])
    assert resp.headers["cache-control"] == "private, no-store"
    assert await count(engine, "purchases", "user_id = :u", u=uid(user)) == 1
    refs = "SELECT count(DISTINCT source_ref) FROM entitlements WHERE user_id = :u"
    assert await scalar(engine, refs, u=uid(user)) == 1  # both point at the one purchase


async def test_the_purchase_row_keeps_facts_and_never_the_proof(
    client: AsyncClient, apple_chain: Chain, engine: AsyncEngine
) -> None:
    user = await register(client)
    proof = signed(apple_chain, await account_token(client, user))
    assert (await claim(client, user, proof)).status_code == 201
    row = await scalar(
        engine,
        "SELECT row_to_json(p)::text FROM purchases p WHERE user_id = :u",
        u=uid(user),
    )
    assert PRODUCT_ID in row
    assert "production" in row
    assert proof not in row
    assert proof.split(".")[0] not in row
    assert proof.split(".")[1] not in row


async def test_the_same_account_again_is_a_replay_with_no_new_rows(
    client: AsyncClient, apple_chain: Chain, engine: AsyncEngine
) -> None:
    user = await register(client)
    proof = signed(apple_chain, await account_token(client, user))
    first = await claim(client, user, proof)
    second = await claim(client, user, proof)
    assert (first.status_code, second.status_code) == (201, 200)
    assert second.json()["ads_removed"] is True
    assert len(second.json()["items"]) == 2
    assert await count(engine, "purchases", "user_id = :u", u=uid(user)) == 1
    assert await count(engine, "entitlements", "user_id = :u", u=uid(user)) == 2


async def test_a_restore_with_a_new_transaction_id_is_a_replay(
    client: AsyncClient, apple_chain: Chain, engine: AsyncEngine
) -> None:
    user = await register(client)
    assert (await buy(client, apple_chain, user)).status_code == 201
    restored = await buy(client, apple_chain, user, transaction_id="2000000999999999")
    assert restored.status_code == 200
    assert await count(engine, "purchases", "user_id = :u", u=uid(user)) == 1


async def test_a_replay_never_grants_a_revoked_entitlement_again(
    client: AsyncClient, apple_chain: Chain, engine: AsyncEngine
) -> None:
    user = await register(client)
    proof = signed(apple_chain, await account_token(client, user))
    assert (await claim(client, user, proof)).status_code == 201
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE entitlements SET revoked_at = now() WHERE user_id = :u"), {"u": uid(user)}
        )
    again = await claim(client, user, proof)
    assert again.status_code == 200
    assert (again.json()["ads_removed"], again.json()["items"]) == (False, [])


async def test_concurrent_submissions_of_one_account_grant_once(
    client: AsyncClient, apple_chain: Chain, engine: AsyncEngine
) -> None:
    user = await register(client)
    proof = signed(apple_chain, await account_token(client, user))
    results = await asyncio.gather(*(claim(client, user, proof) for _ in range(4)))
    assert sorted(r.status_code for r in results) == [200, 200, 200, 201]
    assert await count(engine, "entitlements", "user_id = :u", u=uid(user)) == 2


# --- another account -----------------------------------------------------------------------------


async def test_another_accounts_transaction_is_invalid_for_me(
    client: AsyncClient, apple_chain: Chain, engine: AsyncEngine
) -> None:
    owner, thief = await register(client), await register(client)
    proof = signed(apple_chain, await account_token(client, owner))
    assert (await claim(client, owner, proof)).status_code == 201
    stolen = await claim(client, thief, proof)
    assert stolen.status_code == 400
    assert stolen.json() == INVALID
    assert await count(engine, "entitlements", "user_id = :u", u=uid(thief)) == 0


async def test_the_same_original_transaction_for_another_account_is_a_conflict(
    client: AsyncClient, apple_chain: Chain, engine: AsyncEngine
) -> None:
    first, second = await register(client), await register(client)
    assert (await buy(client, apple_chain, first)).status_code == 201
    # A new transactionId under the same originalTransactionId, carrying the second account's own
    # token: the deduplication is by the original id, and the purchase stays with the first.
    resp = await buy(client, apple_chain, second, transaction_id="2000000888888888")
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "purchase_already_claimed"
    assert await count(engine, "entitlements", "user_id = :u", u=uid(second)) == 0
    assert await count(engine, "purchases", "user_id = :u", u=uid(first)) == 1


async def test_two_accounts_racing_for_one_purchase_cannot_both_win(
    client: AsyncClient, apple_chain: Chain, engine: AsyncEngine
) -> None:
    first, second = await register(client), await register(client)
    results = await asyncio.gather(
        buy(client, apple_chain, first), buy(client, apple_chain, second)
    )
    assert sorted(r.status_code for r in results) == [201, 409]
    assert await count(engine, "purchases") == 1
    assert await count(engine, "entitlements") == 2


async def test_the_same_original_id_in_another_account_does_not_leak_whose_it_is(
    client: AsyncClient, apple_chain: Chain
) -> None:
    first, second = await register(client), await register(client)
    await buy(client, apple_chain, first)
    resp = await buy(client, apple_chain, second, transaction_id="2000000777777777")
    assert first.id not in resp.text
    assert first.email not in resp.text
