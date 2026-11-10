"""``POST /v1/me/purchases``: invalid proofs and the stores of each region."""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from app.email import InMemoryEmailSender
from app.main import create_app
from tests.conftest import make_settings
from tests.grace_helpers import count
from tests.helpers import register
from tests.payments_helpers import (
    BUNDLE_ID,
    PAYMENTS_KEY_B64,
    PRODUCTS,
    Chain,
    make_chain,
    millis,
)
from tests.purchase_helpers import (
    INVALID,
    account_token,
    buy,
    claim,
    signed,
)

pytestmark = pytest.mark.usefixtures("payments_on")


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
