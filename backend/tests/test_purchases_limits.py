"""``POST /v1/me/purchases``: rate and body limits; the account token (ADR 0018 section 6)."""

from __future__ import annotations

from collections.abc import AsyncIterator

import pytest
from httpx import AsyncClient

from app.config import Settings
from tests.helpers import register
from tests.purchase_helpers import (
    ENTITLEMENTS_URL,
    URL,
    account_token,
    claim,
)
from tests.test_data_export_hardening import limiter_down

pytestmark = pytest.mark.usefixtures("payments_on")


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


async def test_the_account_token_is_withheld_while_payments_are_off(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    user = await register(client)
    assert await account_token(client, user)  # on, with a key
    monkeypatch.setattr(settings, "feature_payments", False)
    resp = await client.get(ENTITLEMENTS_URL, headers=user.headers)
    assert resp.json()["app_account_token"] is None


async def test_with_redis_down_the_claim_is_refused_not_unlimited(
    client: AsyncClient, settings: Settings
) -> None:
    user = await register(client)
    async with limiter_down(client, settings):
        resp = await claim(client, user, "garbage")
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "rate_limit_unavailable"


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
