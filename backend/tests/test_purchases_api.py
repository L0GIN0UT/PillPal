"""``POST /v1/me/purchases`` (ADR 0018 section 6): claim, replay, dedup and every refusal."""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from app.email import InMemoryEmailSender
from app.main import create_app
from tests.conftest import make_settings
from tests.grace_helpers import count, scalar
from tests.helpers import User, register
from tests.payments_helpers import (
    BUNDLE_ID,
    PAYMENTS_KEY_B64,
    PRODUCT_ID,
    PRODUCTS,
    Chain,
    make_chain,
    millis,
)
from tests.purchase_helpers import (
    ENTITLEMENTS_URL,
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


async def entitlement_kinds(client: AsyncClient, user: User) -> list[dict[str, Any]]:
    resp = await client.get(ENTITLEMENTS_URL, headers=user.headers)
    return list(resp.json()["items"])


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


# --- refusals ------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "overrides",
    [
        {"bundleId": "com.example.other"},
        {"productId": "ru.pillpal.test.unknown"},
        {"type": "Consumable"},
        {"inAppOwnershipType": "FAMILY_SHARED"},
        {"environment": "Xcode"},
        {"environment": "Sandbox"},
        {"revocationDate": millis(datetime.now(UTC) - timedelta(days=1))},
        {"signedDate": millis(datetime.now(UTC) + timedelta(days=1))},
    ],
)
async def test_an_invalid_transaction_is_a_400_with_one_answer(
    client: AsyncClient, apple_chain: Chain, engine: AsyncEngine, overrides: dict[str, Any]
) -> None:
    user = await register(client)
    token = await account_token(client, user)
    proof = signed(apple_chain, token, **overrides)
    resp = await claim(client, user, proof)
    assert resp.status_code == 400
    assert resp.json() == INVALID
    assert proof not in resp.text
    assert await count(engine, "purchases") == 0


@pytest.mark.parametrize("token", [None, "not-a-uuid", str(uuid.uuid4())])
async def test_a_missing_or_wrong_account_token_is_invalid(
    client: AsyncClient, apple_chain: Chain, token: str | None
) -> None:
    user = await register(client)
    resp = await claim(client, user, signed(apple_chain, token))
    assert resp.status_code == 400
    assert resp.json() == INVALID


async def test_a_chain_to_another_root_is_invalid(client: AsyncClient) -> None:
    user = await register(client)
    stranger = make_chain(around=datetime.now(UTC))
    resp = await claim(client, user, signed(stranger, await account_token(client, user)))
    assert resp.status_code == 400
    assert resp.json() == INVALID


async def test_a_tampered_transaction_is_invalid(client: AsyncClient, apple_chain: Chain) -> None:
    user = await register(client)
    head, _, tail = signed(apple_chain, await account_token(client, user)).split(".")
    forged_body = signed(apple_chain, await account_token(client, user), productId="x").split(".")[
        1
    ]
    resp = await claim(client, user, f"{head}.{forged_body}.{tail}")
    assert resp.status_code == 400
    assert resp.json() == INVALID


async def test_garbage_is_invalid_not_a_server_error(client: AsyncClient) -> None:
    user = await register(client)
    for proof in ("x", "a.b.c", "....", "ж" * 50):
        resp = await claim(client, user, proof)
        assert resp.status_code == 400, proof
        assert resp.json() == INVALID


async def test_the_sandbox_is_accepted_only_when_allowed(
    client: AsyncClient, apple_chain: Chain, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    user = await register(client)
    assert (await buy(client, apple_chain, user, environment="Sandbox")).status_code == 400
    monkeypatch.setattr(settings, "payments_allow_sandbox", True)
    resp = await buy(client, apple_chain, user, environment="Sandbox")
    assert resp.status_code == 201


async def test_the_proof_is_checked_against_the_configured_bundle_and_products(
    client: AsyncClient,
    apple_chain: Chain,
    settings: Settings,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    user = await register(client)
    monkeypatch.setattr(settings, "payments_apple_bundle_id", "ru.pillpal.renamed")
    assert (await buy(client, apple_chain, user)).status_code == 400
    monkeypatch.setattr(settings, "payments_apple_bundle_id", BUNDLE_ID)
    monkeypatch.setattr(settings, "payments_products", {"other.product": "remove_ads"})
    assert (await buy(client, apple_chain, user)).status_code == 400
    monkeypatch.setattr(settings, "payments_products", PRODUCTS)
    assert (await buy(client, apple_chain, user)).status_code == 201


# --- stores --------------------------------------------------------------------------------------


async def test_rustore_is_a_stub_in_ru(client: AsyncClient) -> None:
    user = await register(client)
    resp = await claim(client, user, "token", store="rustore")
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "store_unavailable"


async def test_google_play_is_not_offered_in_ru(client: AsyncClient) -> None:
    user = await register(client)
    resp = await claim(client, user, "token", store="google_play")
    assert resp.status_code == 400
    assert resp.json() == INVALID


async def test_the_app_store_is_unavailable_until_configured(
    client: AsyncClient, apple_chain: Chain, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    user = await register(client)
    token = await account_token(client, user)
    monkeypatch.setattr(settings, "payments_apple_bundle_id", None)
    resp = await claim(client, user, signed(apple_chain, token))
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "store_unavailable"


async def test_without_the_account_key_nothing_can_be_verified(
    client: AsyncClient, apple_chain: Chain, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    user = await register(client)
    proof = signed(apple_chain, await account_token(client, user))
    monkeypatch.setattr(settings, "payments_app_account_key", None)
    resp = await claim(client, user, proof)
    assert resp.status_code == 503


@pytest_asyncio.fixture
async def eu_payments_client(
    app_and_engine: tuple[object, AsyncEngine],
    clean_state: None,
    email_sender: InMemoryEmailSender,
    apple_chain: Chain,
    tmp_path: Path,
) -> AsyncIterator[AsyncClient]:
    """A second app of the EU region: App Store and Google Play."""
    root = tmp_path / "eu-root.cer"
    root.write_bytes(apple_chain.root_der)
    eu = make_settings(
        region="eu",
        feature_payments=True,
        payments_app_account_key=PAYMENTS_KEY_B64,
        payments_apple_bundle_id=BUNDLE_ID,
        payments_products=PRODUCTS,
        payments_apple_root_cert_path=str(root),
    )
    app = create_app(eu, email_sender=email_sender)
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as c:
            yield c


async def test_eu_offers_google_play_as_a_stub_and_refuses_rustore(
    eu_payments_client: AsyncClient,
) -> None:
    user = await register(eu_payments_client, region="eu")
    stub = await claim(eu_payments_client, user, "token", store="google_play")
    assert (stub.status_code, stub.json()["error"]["code"]) == (503, "store_unavailable")
    refused = await claim(eu_payments_client, user, "token", store="rustore")
    assert (refused.status_code, refused.json()) == (400, INVALID)


async def test_eu_verifies_the_app_store_too(
    eu_payments_client: AsyncClient, apple_chain: Chain
) -> None:
    user = await register(eu_payments_client, region="eu")
    resp = await buy(eu_payments_client, apple_chain, user)
    assert resp.status_code == 201


# --- limits --------------------------------------------------------------------------------------


async def test_attempts_are_rate_limited_per_account(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "payments_rate_limit_attempts", 2)
    user = await register(client)
    first = [(await claim(client, user, "garbage")).status_code for _ in range(2)]
    assert first == [400, 400]
    limited = await claim(client, user, "garbage")
    assert limited.status_code == 429
    assert limited.json()["error"]["code"] == "rate_limited"
    assert int(limited.headers["retry-after"]) > 0


async def test_an_oversized_body_is_refused_before_it_is_parsed(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "payments_max_body_bytes", 1024)
    user = await register(client)
    big = {"store": "app_store", "signed_transaction": "a" * 2000}
    resp = await client.post(URL, json=big, headers=user.headers)
    assert resp.status_code == 413
    assert resp.json()["error"]["code"] == "payload_too_large"
    assert "a" * 100 not in resp.text


async def test_an_oversized_chunked_body_is_refused_too(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "payments_max_body_bytes", 1024)
    user = await register(client)

    async def chunks() -> AsyncIterator[bytes]:
        for _ in range(8):  # no Content-Length: the limit counts the bytes as they arrive
            yield b" " * 400

    resp = await client.post(
        URL, content=chunks(), headers={**user.headers, "Content-Type": "application/json"}
    )
    assert resp.status_code == 413
    assert resp.json()["error"]["code"] == "payload_too_large"


async def test_a_body_at_the_limit_still_reaches_the_endpoint(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "payments_max_body_bytes", 1024)
    user = await register(client)
    resp = await claim(client, user, "g" * 900)
    assert resp.status_code == 400  # read and judged, not cut off


async def test_other_routes_are_not_cut_by_the_purchase_limit(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "payments_max_body_bytes", 1024)
    resp = await client.post("/v1/auth/login", json={"email": "a" * 2000, "password": "x"})
    assert resp.status_code != 413


# --- the account token ---------------------------------------------------------------------------


async def test_the_account_token_is_stable_per_account_and_differs_between_accounts(
    client: AsyncClient,
) -> None:
    one, two = await register(client), await register(client)
    first = await account_token(client, one)
    assert await account_token(client, one) == first
    assert await account_token(client, two) != first


async def test_the_account_token_is_absent_without_a_configured_key(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    user = await register(client)
    monkeypatch.setattr(settings, "payments_app_account_key", None)
    resp = await client.get(ENTITLEMENTS_URL, headers=user.headers)
    assert resp.status_code == 200
    assert resp.json()["app_account_token"] is None


async def test_the_token_is_an_additive_field_of_the_entitlements_answer(
    client: AsyncClient,
) -> None:
    user = await register(client)
    body = (await client.get(ENTITLEMENTS_URL, headers=user.headers)).json()
    assert set(body) == {
        "ads_removed",
        "limits_lifted",
        "items",
        "server_time",
        "app_account_token",
    }
