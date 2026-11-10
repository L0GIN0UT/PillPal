"""Apple and Google through the HTTP API with the real verifiers (milestone 5.8, ADR 0017).

An EU app on the shared test database, provider endpoints served by ``httpx.MockTransport``, tokens
signed with keys generated in the tests. The refresh token of Apple is stored sealed, revoked after
the deletion request commits and on unlink; no token, code or key reaches the logs.
"""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from app.main import create_app
from app.oauth.apple import APPLE_ISSUER, APPLE_JWKS_URL
from app.oauth.apple_tokens import APPLE_REVOKE_URL, APPLE_TOKEN_URL
from app.oauth.google import GOOGLE_JWKS_URL
from app.services.data_encryption import DataKeyring
from app.services.provider_tokens import REFRESH_PURPOSE
from tests.conftest import make_settings
from tests.grace_helpers import scalar
from tests.helpers import DEFAULT_PASSWORD, register
from tests.identity_helpers import IDENTITIES_URL
from tests.oauth_helpers import CONSENTS, new_nonce, ticket_of
from tests.oauth_real_helpers import (
    APPLE_CLIENT_ID,
    APPLE_SETTINGS,
    CODE,
    GOOGLE_ANDROID_ID,
    REFRESH_TOKEN,
    AppleEndpoints,
    JwksServer,
    claims,
    sign,
    timeout,
)

SUBJECT = "apple-subject-synthetic"
GOOGLE_SUBJECT = "google-subject-synthetic"
EMAIL = "apple-user@example.com"


@dataclass
class Real:
    client: AsyncClient
    apple: AppleEndpoints
    jwks: JwksServer
    engine: AsyncEngine

    def apple_token(self, nonce: str, **extra: Any) -> str:
        body = claims(
            issuer=APPLE_ISSUER,
            audience=APPLE_CLIENT_ID,
            nonce=nonce,
            now=datetime.now(UTC),
            sub=SUBJECT,
            email=EMAIL,
            **extra,
        )
        return sign(body)

    def google_token(self, nonce: str) -> str:
        body = claims(
            issuer="https://accounts.google.com",
            audience=GOOGLE_ANDROID_ID,
            nonce=nonce,
            now=datetime.now(UTC),
            sub=GOOGLE_SUBJECT,
            email="google-user@example.com",
        )
        return sign(body)

    async def apple_sign_in(self, *, code: str | None = CODE, **extra: Any) -> httpx.Response:
        nonce = await new_nonce(self.client)
        body: dict[str, Any] = {
            "platform": "ios",
            "assertion": self.apple_token(nonce, **extra),
            "nonce": nonce,
        }
        if code is not None:
            body["authorization_code"] = code
        return await self.client.post("/v1/auth/oauth/apple/sign-in", json=body)

    async def apple_account(self, *, code: str | None = CODE) -> dict[str, Any]:
        """Sign in (unknown identity, 409 with a ticket) and sign up with the provider address."""
        ticket = ticket_of(await self.apple_sign_in(code=code))
        resp = await self.client.post(
            "/v1/auth/oauth/sign-up",
            json={"signup_ticket": ticket, "region": "eu", "consents": CONSENTS},
        )
        assert resp.status_code == 201, resp.text
        return dict(resp.json())

    async def reauth_apple(self, headers: dict[str, str]) -> dict[str, Any]:
        nonce = await new_nonce(self.client, "reauth", headers)
        return {
            "reauth": {
                "provider": "apple",
                "platform": "ios",
                "assertion": self.apple_token(nonce),
                "nonce": nonce,
            }
        }

    async def sealed(self) -> bytes | None:
        value = await scalar(
            self.engine, "SELECT provider_refresh_token_enc FROM auth_identities LIMIT 1"
        )
        return None if value is None else bytes(value)

    def revokes(self) -> list[dict[str, str]]:
        return [form for url, form in self.apple.calls if url == APPLE_REVOKE_URL]


def router(real: dict[str, Any]) -> Any:
    def route(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if url in (APPLE_JWKS_URL, GOOGLE_JWKS_URL):
            return real["jwks"].handler(request)
        if url in (APPLE_TOKEN_URL, APPLE_REVOKE_URL):
            return real["apple"].handler(request)
        return httpx.Response(404)

    return route


@pytest_asyncio.fixture
async def real(
    app_and_engine: tuple[object, AsyncEngine], clean_state: None, email_sender: Any
) -> AsyncIterator[Real]:
    parts: dict[str, Any] = {"apple": AppleEndpoints(), "jwks": JwksServer()}
    parts["apple"].subject = SUBJECT
    settings = make_settings(
        **{
            **APPLE_SETTINGS,
            "feature_oauth": True,
            "oauth_google_client_id": GOOGLE_ANDROID_ID,
        }
    )
    app = create_app(
        settings, email_sender=email_sender, oauth_transport=httpx.MockTransport(router(parts))
    )
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield Real(client, parts["apple"], parts["jwks"], app_and_engine[1])


def bearer(tokens: dict[str, Any]) -> dict[str, str]:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


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


# --- revoke on deletion -------------------------------------------------------------------------


async def test_deletion_revokes_at_apple_and_clears_the_column(real: Real) -> None:
    tokens = await real.apple_account()
    headers = bearer(tokens)
    resp = await real.client.request(
        "DELETE", "/v1/me", json=await real.reauth_apple(headers), headers=headers
    )
    assert resp.status_code == 204, resp.text
    [form] = real.revokes()
    assert form["token"] == REFRESH_TOKEN
    assert await real.sealed() is None


async def test_a_revoke_failure_does_not_fail_the_deletion(real: Real) -> None:
    tokens = await real.apple_account()
    headers = bearer(tokens)
    real.apple.revoke_responses = [httpx.Response(500), httpx.Response(500)]
    resp = await real.client.request(
        "DELETE", "/v1/me", json=await real.reauth_apple(headers), headers=headers
    )
    assert resp.status_code == 204, resp.text
    assert len(real.revokes()) == 2  # one try and one retry
    pending = await scalar(
        real.engine, "SELECT count(*) FROM users WHERE deletion_requested_at IS NOT NULL"
    )
    assert pending == 1
    assert await real.sealed() is None


async def test_a_stale_reauth_assertion_cannot_delete(real: Real) -> None:
    tokens = await real.apple_account()
    headers = bearer(tokens)
    nonce = await new_nonce(real.client, "reauth", headers)
    stale = int((datetime.now(UTC) - timedelta(minutes=30)).timestamp())
    body = {
        "reauth": {
            "provider": "apple",
            "platform": "ios",
            "assertion": real.apple_token(nonce, iat=stale),
            "nonce": nonce,
        }
    }
    resp = await real.client.request("DELETE", "/v1/me", json=body, headers=headers)
    assert resp.status_code == 401
    assert real.revokes() == []


# --- revoke on unlink ---------------------------------------------------------------------------


async def test_unlinking_apple_revokes_the_token(real: Real) -> None:
    user = await register(real.client, region="eu")
    nonce = await new_nonce(real.client, "link", user.headers)
    body = {
        "provider": "apple",
        "platform": "ios",
        "assertion": real.apple_token(nonce),
        "nonce": nonce,
        "authorization_code": CODE,
        "password": DEFAULT_PASSWORD,
    }
    linked = await real.client.post(IDENTITIES_URL, json=body, headers=user.headers)
    assert linked.status_code == 201, linked.text
    assert await real.sealed() is not None
    resp = await real.client.request(
        "DELETE",
        f"{IDENTITIES_URL}/{linked.json()['id']}",
        json={"password": DEFAULT_PASSWORD},
        headers=user.headers,
    )
    assert resp.status_code == 204, resp.text
    [form] = real.revokes()
    assert form["token"] == REFRESH_TOKEN


async def test_an_unlink_still_succeeds_when_apple_refuses_the_revoke(real: Real) -> None:
    user = await register(real.client, region="eu")
    nonce = await new_nonce(real.client, "link", user.headers)
    body = {
        "provider": "apple",
        "platform": "ios",
        "assertion": real.apple_token(nonce),
        "nonce": nonce,
        "authorization_code": CODE,
        "password": DEFAULT_PASSWORD,
    }
    linked = await real.client.post(IDENTITIES_URL, json=body, headers=user.headers)
    real.apple.revoke_responses = [httpx.Response(400), httpx.Response(400)]
    resp = await real.client.request(
        "DELETE",
        f"{IDENTITIES_URL}/{linked.json()['id']}",
        json={"password": DEFAULT_PASSWORD},
        headers=user.headers,
    )
    assert resp.status_code == 204


# --- logs ---------------------------------------------------------------------------------------


async def test_no_token_code_or_subject_reaches_the_logs(
    real: Real, capsys: pytest.CaptureFixture[str]
) -> None:
    real.apple.revoke_responses = [httpx.Response(500, text=REFRESH_TOKEN)] * 2
    tokens = await real.apple_account()
    headers = bearer(tokens)
    await real.client.request(
        "DELETE", "/v1/me", json=await real.reauth_apple(headers), headers=headers
    )
    out = capsys.readouterr()
    everything = out.out + out.err
    for secret in (REFRESH_TOKEN, CODE, SUBJECT):
        assert secret not in everything
