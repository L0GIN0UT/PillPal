"""Apple and Google through the HTTP API with the real verifiers (milestone 5.8, ADR 0017): sign-in,
sign-up, replay, outages and the stored refresh token. Revoking is in ``test_oauth_revoke_flow``."""

from __future__ import annotations

import uuid

import httpx
import pytest  # noqa: F401
from httpx import AsyncClient  # noqa: F401

from app.oauth.apple_tokens import APPLE_TOKEN_URL
from app.services.data_encryption import DataKeyring
from app.services.provider_tokens import REFRESH_PURPOSE
from tests.conftest import make_settings
from tests.grace_helpers import count, scalar
from tests.oauth_helpers import CONSENTS, new_nonce, ticket_of
from tests.oauth_real_flow_helpers import Real, bearer
from tests.oauth_real_helpers import APPLE_SETTINGS, REFRESH_TOKEN, timeout

# --- sign-in with the real verifier -------------------------------------------------------------


async def test_apple_sign_up_and_sign_in_with_a_real_token(real: Real) -> None:
    tokens = await real.apple_account()
    resp = await real.apple_sign_in()
    assert resp.status_code == 200, resp.text
    assert resp.json()["access_token"]
    assert tokens["access_token"]


async def test_the_providers_list_shows_apple_and_google_when_configured(real: Real) -> None:
    ios = await real.client.get("/v1/auth/providers", params={"platform": "ios"})
    android = await real.client.get("/v1/auth/providers", params={"platform": "android"})
    assert [p["provider"] for p in ios.json()["providers"]] == ["apple"]
    assert [p["provider"] for p in android.json()["providers"]] == ["google"]


async def test_the_fake_assertion_format_is_not_accepted_by_the_real_verifier(real: Real) -> None:
    nonce = await new_nonce(real.client)
    fake = '{"sub": "x", "nonce": "y"}'
    resp = await real.client.post(
        "/v1/auth/oauth/apple/sign-in",
        json={"platform": "ios", "assertion": fake, "nonce": nonce},
    )
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_provider_token"


async def test_a_replayed_token_is_refused(real: Real) -> None:
    nonce = await new_nonce(real.client)
    body = {"platform": "ios", "assertion": real.apple_token(nonce), "nonce": nonce}
    first = await real.client.post("/v1/auth/oauth/apple/sign-in", json=body)
    second = await real.client.post("/v1/auth/oauth/apple/sign-in", json=body)
    assert first.status_code == 409  # unknown identity: a sign-up ticket
    assert second.status_code == 401


async def test_a_claimed_platform_cannot_pick_a_looser_verifier(real: Real) -> None:
    # A Google token with the Android audience, claimed as iOS (no iOS client id configured).
    nonce = await new_nonce(real.client)
    resp = await real.client.post(
        "/v1/auth/oauth/google/sign-in",
        json={"platform": "ios", "assertion": real.google_token(nonce), "nonce": nonce},
    )
    assert resp.status_code == 404  # not offered on iOS at all


async def test_a_jwks_timeout_is_503(real: Real) -> None:
    real.jwks.fail = timeout
    resp = await real.apple_sign_in()
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "provider_unreachable"


async def test_google_sign_in_with_a_real_token(real: Real) -> None:
    nonce = await new_nonce(real.client)
    resp = await real.client.post(
        "/v1/auth/oauth/google/sign-in",
        json={"platform": "android", "assertion": real.google_token(nonce), "nonce": nonce},
    )
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "oauth_signup_required"


# --- the refresh token --------------------------------------------------------------------------


async def test_sign_up_stores_the_refresh_token_sealed(real: Real) -> None:
    await real.apple_account()
    sealed = await real.sealed()
    assert sealed is not None
    assert REFRESH_TOKEN.encode() not in sealed
    keyring = DataKeyring.from_settings(make_settings(**APPLE_SETTINGS))
    assert keyring is not None
    identity_id = uuid.UUID(str(await scalar(real.engine, "SELECT id FROM auth_identities")))
    assert keyring.decrypt(REFRESH_PURPOSE, identity_id, sealed) == REFRESH_TOKEN.encode()


async def test_sign_up_without_a_code_stores_nothing_and_a_later_sign_in_stores_it(
    real: Real,
) -> None:
    await real.apple_account(code=None)
    assert await real.sealed() is None
    resp = await real.apple_sign_in()
    assert resp.status_code == 200, resp.text
    assert await real.sealed() is not None


async def test_a_failed_exchange_does_not_fail_the_sign_in(real: Real) -> None:
    real.apple.token_response = httpx.Response(500)
    await real.apple_account()
    assert await real.sealed() is None


async def test_the_exchange_is_not_repeated_while_a_token_is_stored(real: Real) -> None:
    await real.apple_account()
    exchanges = len([1 for url, _ in real.apple.calls if url == APPLE_TOKEN_URL])
    assert (await real.apple_sign_in()).status_code == 200
    assert len([1 for url, _ in real.apple.calls if url == APPLE_TOKEN_URL]) == exchanges


async def test_google_aud_is_the_server_id_and_a_wrong_azp_is_refused(real: Real) -> None:
    nonce = await new_nonce(real.client)
    body = real.google_token(nonce)
    good = await real.client.post(
        "/v1/auth/oauth/google/sign-in",
        json={"platform": "android", "assertion": body, "nonce": nonce},
    )
    assert good.status_code == 409  # a valid token of an unknown identity: a sign-up ticket
    nonce = await new_nonce(real.client)
    bad = await real.client.post(
        "/v1/auth/oauth/google/sign-in",
        json={
            "platform": "android",
            "assertion": real.google_token(nonce, azp="some-other-client"),
            "nonce": nonce,
        },
    )
    assert bad.status_code == 401


async def test_a_token_dropped_by_the_email_fallback_is_revoked(real: Real) -> None:
    ticket = ticket_of(await real.apple_sign_in(email_verified=False))
    assert [url for url, _ in real.apple.calls].count(APPLE_TOKEN_URL) == 1
    resp = await real.client.post(
        "/v1/auth/oauth/sign-up",
        json={
            "signup_ticket": ticket,
            "region": "eu",
            "consents": CONSENTS,
            "email": "fallback-user@example.com",
        },
    )
    assert resp.status_code == 202, resp.text
    [form] = real.revokes()  # the fallback stores no token, so the exchanged one is ended
    assert form["token"] == REFRESH_TOKEN
    assert await count(real.engine, "auth_identities") == 0  # nothing is linked yet


async def test_a_code_for_an_account_pending_deletion_is_not_exchanged(real: Real) -> None:
    tokens = await real.apple_account(code=None)
    headers = bearer(tokens)
    resp = await real.client.request(
        "DELETE", "/v1/me", json=await real.reauth_apple(headers), headers=headers
    )
    assert resp.status_code == 204, resp.text
    await real.apple_sign_in()  # answers with the restore offer, not tokens
    assert [url for url, _ in real.apple.calls].count(APPLE_TOKEN_URL) == 0
    assert await real.sealed() is None
