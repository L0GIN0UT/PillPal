"""OAuth sign-in (ADR 0017 sections 1, 3, 4): providers, nonce, assertion checks, known identity."""

from __future__ import annotations

import base64
import time
from collections.abc import Callable
from contextlib import AbstractAsyncContextManager
from datetime import UTC, datetime, timedelta

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from tests.grace_helpers import count, restore, scalar
from tests.helpers import last_code, register
from tests.oauth_helpers import (
    bearer,
    new_nonce,
    oauth_account,
    redis_client,
    redis_keys,
    sign_in,
    sign_up,
    ticket_of,
)

# --- providers ----------------------------------------------------------------------------------


async def test_providers_are_empty_while_the_feature_is_off(client: AsyncClient) -> None:
    resp = await client.get("/v1/auth/providers", params={"platform": "android"})
    assert resp.status_code == 200
    assert resp.json() == {"providers": []}


@pytest.mark.usefixtures("oauth_on")
@pytest.mark.parametrize(
    ("platform", "expected"), [("android", ["vk_id", "yandex_id"]), ("ios", [])]
)
async def test_ru_offers_vk_and_yandex_on_android_only(
    client: AsyncClient, platform: str, expected: list[str]
) -> None:
    resp = await client.get("/v1/auth/providers", params={"platform": platform})
    assert resp.status_code == 200
    assert [p["provider"] for p in resp.json()["providers"]] == expected


@pytest.mark.parametrize(
    ("platform", "expected"), [("android", ["google"]), ("ios", ["apple", "google"])]
)
async def test_eu_offers_apple_on_ios_and_google_everywhere(
    eu_client: AsyncClient, platform: str, expected: list[str]
) -> None:
    resp = await eu_client.get("/v1/auth/providers", params={"platform": platform})
    assert [p["provider"] for p in resp.json()["providers"]] == expected


@pytest.mark.usefixtures("oauth_on")
@pytest.mark.parametrize("params", [{}, {"platform": "web"}, {"platform": ""}])
async def test_providers_validate_the_platform(client: AsyncClient, params: dict[str, str]) -> None:
    resp = await client.get("/v1/auth/providers", params=params)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "validation_error"


# --- the feature flag and the matrix ------------------------------------------------------------


async def test_every_oauth_route_is_404_while_the_feature_is_off(client: AsyncClient) -> None:
    nonce = await client.post("/v1/auth/oauth/nonce", json={"purpose": "sign_in"})
    sign_in_resp = await sign_in(client, nonce="n" * 43)
    sign_up_resp = await sign_up(client, "ticket")
    for resp in (nonce, sign_in_resp, sign_up_resp):
        assert resp.status_code == 404, resp.text
        assert resp.json()["error"]["code"] == "not_found"


@pytest.mark.usefixtures("oauth_on")
@pytest.mark.parametrize(
    ("provider", "platform"),
    [
        ("apple", "ios"),  # not a provider of RU
        ("google", "android"),
        ("vk_id", "ios"),  # RU-iOS is e-mail only
        ("yandex_id", "ios"),
        ("facebook", "android"),  # unknown
    ],
)
async def test_a_provider_the_matrix_refuses_is_404(
    client: AsyncClient, provider: str, platform: str
) -> None:
    resp = await sign_in(client, provider, platform=platform)
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "not_found"
    assert await count(client_engine(client), "users") == 0


def client_engine(client: AsyncClient) -> AsyncEngine:
    app = client._transport.app  # type: ignore[attr-defined]
    engine: AsyncEngine = app.state.engine
    return engine


@pytest.mark.parametrize(
    ("provider", "platform", "status"),
    [
        ("vk_id", "android", 404),  # not a provider of EU
        ("apple", "android", 404),  # Apple is iOS only
        ("apple", "ios", 409),
        ("google", "android", 409),
        ("google", "ios", 409),
    ],
)
async def test_eu_follows_the_matrix(
    eu_client: AsyncClient, provider: str, platform: str, status: int
) -> None:
    resp = await sign_in(eu_client, provider, platform=platform, email="a@example.com")
    assert resp.status_code == status, resp.text


# --- the nonce ----------------------------------------------------------------------------------


@pytest.mark.usefixtures("oauth_on")
async def test_a_nonce_has_at_least_128_bits_and_a_ttl(client: AsyncClient) -> None:
    resp = await client.post("/v1/auth/oauth/nonce", json={"purpose": "sign_in"})
    assert resp.status_code == 200
    body = resp.json()
    raw = base64.urlsafe_b64decode(body["nonce"] + "=" * (-len(body["nonce"]) % 4))
    assert len(raw) * 8 >= 128
    assert body["expires_in"] == 300
    keys = [k for k in await redis_keys() if k.startswith("oc:")]
    assert len(keys) == 1
    assert body["nonce"] not in keys[0]  # only a hash of it is stored
    async with redis_client() as redis:
        assert 0 < await redis.ttl(keys[0]) <= 300


@pytest.mark.usefixtures("oauth_on")
async def test_nonces_are_unique(client: AsyncClient) -> None:
    assert len({await new_nonce(client) for _ in range(5)}) == 5


@pytest.mark.usefixtures("oauth_on")
@pytest.mark.parametrize("body", [{}, {"purpose": "other"}, {"purpose": "sign_in", "x": 1}])
async def test_the_nonce_request_is_validated(client: AsyncClient, body: dict[str, object]) -> None:
    resp = await client.post("/v1/auth/oauth/nonce", json=body)
    assert resp.status_code == 422


@pytest.mark.usefixtures("oauth_on")
async def test_a_nonce_is_single_use(client: AsyncClient) -> None:
    nonce = await new_nonce(client)
    first = await sign_in(client, nonce=nonce, email="a@example.com")
    assert first.status_code == 409  # a valid sign-in: no account yet
    again = await sign_in(client, nonce=nonce, email="a@example.com", sub="another")
    assert again.status_code == 401
    assert again.json()["error"]["code"] == "invalid_provider_token"


@pytest.mark.usefixtures("oauth_on")
@pytest.mark.parametrize("purpose", ["link", "reauth"])
async def test_a_nonce_of_another_purpose_is_refused(client: AsyncClient, purpose: str) -> None:
    resp = await sign_in(client, purpose=purpose, email="a@example.com")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_provider_token"
    # Spent by the refusal: it cannot be retried at the right endpoint either.
    assert [k for k in await redis_keys() if k.startswith("oc:")] == []


@pytest.mark.usefixtures("oauth_on")
async def test_the_client_cannot_choose_the_nonce(client: AsyncClient) -> None:
    resp = await sign_in(client, nonce="client-chosen-nonce-0123456789", email="a@example.com")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_provider_token"


@pytest.mark.usefixtures("oauth_on")
async def test_a_token_for_another_nonce_is_refused(client: AsyncClient) -> None:
    other = await new_nonce(client)
    resp = await sign_in(client, token_nonce=other, email="a@example.com")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_provider_token"


@pytest.mark.usefixtures("oauth_on")
async def test_sign_in_without_a_nonce_is_refused(client: AsyncClient) -> None:
    body = {"platform": "android", "assertion": "{}"}
    resp = await client.post("/v1/auth/oauth/vk_id/sign-in", json=body)
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_provider_token"


@pytest.mark.usefixtures("oauth_on")
async def test_an_expired_assertion_is_refused(client: AsyncClient) -> None:
    resp = await sign_in(client, email="a@example.com", exp=time.time() - 5)
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_provider_token"


@pytest.mark.usefixtures("oauth_on")
async def test_a_replayed_assertion_is_refused_even_with_a_fresh_nonce(
    client: AsyncClient,
) -> None:
    first = await sign_in(client, email="a@example.com", jti="same-token")
    assert first.status_code == 409
    replay = await sign_in(client, email="a@example.com", jti="same-token")
    assert replay.status_code == 401
    assert replay.json()["error"]["code"] == "invalid_provider_token"
    keys = [k for k in await redis_keys() if k.startswith("on:")]
    assert len(keys) == 1
    assert "same-token" not in keys[0]
    async with redis_client() as redis:
        assert 0 < await redis.ttl(keys[0]) <= 301


@pytest.mark.usefixtures("oauth_on")
async def test_a_replay_marker_lives_until_the_assertion_expires(client: AsyncClient) -> None:
    exp = datetime.now(UTC) + timedelta(seconds=120)
    await sign_in(client, email="a@example.com", exp=exp.timestamp())
    keys = [k for k in await redis_keys() if k.startswith("on:")]
    async with redis_client() as redis:
        assert 60 < await redis.ttl(keys[0]) <= 122


@pytest.mark.usefixtures("oauth_on")
@pytest.mark.parametrize(
    "body",
    [
        {},
        {"platform": "android"},
        {"platform": "web", "assertion": "x", "nonce": "n" * 43},
        {"platform": "android", "assertion": "", "nonce": "n" * 43},
        {"platform": "android", "assertion": "x" * 8193, "nonce": "n" * 43},
        {"platform": "android", "assertion": "x", "nonce": "short"},
        {"platform": "android", "assertion": "x", "nonce": "n" * 43, "code_verifier": "short"},
        {"platform": "android", "assertion": "x", "nonce": "n" * 43, "extra": 1},
    ],
)
async def test_the_sign_in_body_is_validated(client: AsyncClient, body: dict[str, object]) -> None:
    resp = await client.post("/v1/auth/oauth/vk_id/sign-in", json=body)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "validation_error"


# --- the outcome of a sign-in -------------------------------------------------------------------


@pytest.mark.usefixtures("oauth_on")
async def test_an_unknown_identity_gets_a_ticket_bound_to_region_and_platform(
    client: AsyncClient, settings: Settings
) -> None:
    resp = await sign_in(client, email="New@Example.com", verified=True)
    assert resp.status_code == 409
    error = resp.json()["error"]
    assert error["code"] == "oauth_signup_required"
    assert error["details"]["email_required"] is False
    ticket = error["details"]["signup_ticket"]
    keys = [k for k in await redis_keys() if k.startswith("ot:")]
    assert len(keys) == 1
    assert ticket not in keys[0]
    async with redis_client() as redis:
        assert 0 < await redis.ttl(keys[0]) <= settings.oauth_signup_ticket_ttl_seconds
        stored = (await redis.get(keys[0])).decode()
    assert '"region": "ru"' in stored
    assert '"platform": "android"' in stored
    assert await count(client_engine(client), "users") == 0  # nothing is created yet


@pytest.mark.usefixtures("oauth_on")
async def test_a_known_identity_gets_tokens_and_the_row_is_touched(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    created = await oauth_account(client)
    before = await scalar(engine, "SELECT last_used_at FROM auth_identities")
    resp = await sign_in(client, email="oauth-user@example.com", headers={"X-Device-ID": "dev-2"})
    assert resp.status_code == 200, resp.text
    tokens = resp.json()
    assert tokens["token_type"] == "bearer"
    assert tokens["refresh_token"]
    me = await client.get("/v1/me", headers=bearer(tokens))
    assert me.status_code == 200
    assert me.json()["email"] == "oauth-user@example.com"
    assert me.json()["id"] == (await client.get("/v1/me", headers=bearer(created))).json()["id"]
    assert await scalar(engine, "SELECT last_used_at FROM auth_identities") >= before
    assert await count(engine, "devices", "device_id = 'dev-2'") == 1


@pytest.mark.usefixtures("oauth_on")
async def test_a_known_identity_signs_in_without_a_provider_address(client: AsyncClient) -> None:
    await oauth_account(client)
    resp = await sign_in(client)  # the provider asserts no e-mail this time
    assert resp.status_code == 200


@pytest.mark.usefixtures("oauth_on")
async def test_a_verified_address_of_a_verified_account_is_a_409_without_a_ticket(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner = await register(client, email="owner@example.com")
    resp = await sign_in(client, email="Owner@Example.com", verified=True)
    assert resp.status_code == 409
    error = resp.json()["error"]
    assert error["code"] == "oauth_account_exists"
    assert "details" not in error  # no ticket: there is nothing to sign up
    assert not [k for k in await redis_keys() if k.startswith("ot:")]
    assert await count(engine, "users") == 1
    assert await count(engine, "auth_identities") == 0  # no automatic merge
    assert (await client.get("/v1/me", headers=owner.headers)).status_code == 200


@pytest.mark.usefixtures("oauth_on")
async def test_an_unverified_provider_address_never_collides(client: AsyncClient) -> None:
    await register(client, email="owner@example.com")
    resp = await sign_in(client, email="owner@example.com", verified=False)
    assert ticket_of(resp)  # a provider's unverified claim proves nothing and is not an oracle


@pytest.mark.usefixtures("oauth_on")
async def test_a_pending_deletion_account_is_offered_the_restore_not_tokens(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    tokens = await oauth_account(client)
    user_id = (await client.get("/v1/me", headers=bearer(tokens))).json()["id"]
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE users SET deletion_requested_at = now(), "
                "erase_after = now() + interval '30 days' WHERE id = CAST(:u AS uuid)"
            ),
            {"u": user_id},
        )
    resp = await sign_in(client, email="oauth-user@example.com")
    assert resp.status_code == 403
    error = resp.json()["error"]
    assert error["code"] == "account_pending_deletion"
    assert "access_token" not in resp.text
    ticket = error["details"]["restore_ticket"]
    # The assertion alone restores nothing: the ticket needs the mailed code.
    assert (await restore(client, ticket, None)).status_code == 401
    code = last_code(client, "oauth-user@example.com", "restore_account")
    restored = await restore(client, ticket, code)
    assert restored.status_code == 200, restored.text
    assert (await sign_in(client, email="oauth-user@example.com")).status_code == 200


@pytest.mark.usefixtures("oauth_on")
async def test_a_provider_timeout_is_a_503(client: AsyncClient) -> None:
    resp = await sign_in(client, fail="unreachable")
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "provider_unreachable"


# --- Redis down: nothing is accepted without the nonce and replay checks ------------------------


@pytest.mark.usefixtures("oauth_on")
async def test_without_redis_the_nonce_endpoint_is_a_503(
    client: AsyncClient, redis_outage: Callable[[], AbstractAsyncContextManager[None]]
) -> None:
    async with redis_outage():
        resp = await client.post("/v1/auth/oauth/nonce", json={"purpose": "sign_in"})
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "provider_unreachable"


@pytest.mark.usefixtures("oauth_on")
async def test_without_redis_sign_in_accepts_nothing(
    client: AsyncClient, redis_outage: Callable[[], AbstractAsyncContextManager[None]]
) -> None:
    created = await oauth_account(client)  # a known identity: the strongest case
    nonce = await new_nonce(client)
    async with redis_outage():
        resp = await sign_in(client, nonce=nonce, email="oauth-user@example.com")
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "provider_unreachable"
    assert "access_token" not in resp.text
    assert created["access_token"]


@pytest.mark.usefixtures("oauth_on")
async def test_without_redis_sign_up_is_a_503_and_creates_nothing(
    client: AsyncClient,
    engine: AsyncEngine,
    redis_outage: Callable[[], AbstractAsyncContextManager[None]],
) -> None:
    ticket = ticket_of(await sign_in(client, email="a@example.com"))
    async with redis_outage():
        resp = await sign_up(client, ticket)
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "provider_unreachable"
    assert await count(engine, "users") == 0
    assert (await sign_up(client, ticket)).status_code == 201  # the ticket survived the outage


# --- rate limits --------------------------------------------------------------------------------


@pytest.mark.usefixtures("oauth_on")
async def test_the_nonce_endpoint_is_limited_per_account(client: AsyncClient) -> None:
    user = await register(client)
    statuses = [
        (
            await client.post(
                "/v1/auth/oauth/nonce", json={"purpose": "reauth"}, headers=user.headers
            )
        ).status_code
        for _ in range(21)
    ]
    assert statuses[:20] == [200] * 20
    assert statuses[20] == 429


@pytest.mark.usefixtures("oauth_on")
async def test_sign_up_is_limited_per_ticket(client: AsyncClient) -> None:
    statuses = [(await sign_up(client, "guessed-ticket")).status_code for _ in range(21)]
    assert set(statuses[:20]) == {401}
    assert statuses[20] == 429
