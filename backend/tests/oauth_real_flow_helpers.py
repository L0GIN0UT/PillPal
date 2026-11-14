"""Fixtures of the Apple and Google API suites (milestone 5.8): an EU app on the shared test
database with the real verifiers, provider endpoints served by ``httpx.MockTransport`` and tokens
signed with keys generated in the tests. The ``real`` fixture is in ``tests/conftest.py``."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

import httpx
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from app.main import create_app
from app.oauth.apple import APPLE_ISSUER, APPLE_JWKS_URL
from app.oauth.apple_tokens import APPLE_REVOKE_URL, APPLE_TOKEN_URL
from app.oauth.google import GOOGLE_JWKS_URL
from app.services.provider_tokens import revoke_pending_tokens
from tests.grace_helpers import scalar
from tests.helpers import DEFAULT_NAME
from tests.oauth_helpers import CONSENTS, new_nonce, ticket_of
from tests.oauth_real_helpers import (
    APPLE_CLIENT_ID,
    APPLE_SETTINGS,
    CODE,
    GOOGLE_ANDROID_ID,
    GOOGLE_SERVER_ID,
    AppleEndpoints,
    JwksServer,
    claims,
    sign,
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
    app: Any

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

    def google_token(self, nonce: str, **extra: Any) -> str:
        extra.setdefault("azp", GOOGLE_ANDROID_ID)
        body = claims(
            issuer="https://accounts.google.com",
            audience=GOOGLE_SERVER_ID,  # the apps ask for the server: aud = web client
            nonce=nonce,
            now=datetime.now(UTC),
            sub=GOOGLE_SUBJECT,
            email="google-user@example.com",
            **extra,
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
            json={
                "signup_ticket": ticket,
                "region": "eu",
                "display_name": DEFAULT_NAME,
                "consents": CONSENTS,
            },
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

    def tokens(self) -> Any:
        """The provider token helper of the running app (the worker builds its own)."""
        return self.app.state.oauth_providers.tokens

    async def sweep(self, now: datetime | None = None, *, limit: int = 50) -> int:
        """One run of the worker sweep over accounts pending deletion (``limit`` = page size)."""
        return await revoke_pending_tokens(
            self.app.state.sessionmaker, self.tokens(), now or datetime.now(UTC), limit=limit
        )


def router(real: dict[str, Any]) -> Any:
    def route(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if url in (APPLE_JWKS_URL, GOOGLE_JWKS_URL):
            return real["jwks"].handler(request)
        if url in (APPLE_TOKEN_URL, APPLE_REVOKE_URL):
            return real["apple"].handler(request)
        return httpx.Response(404)

    return route


@asynccontextmanager
async def real_context(engine: AsyncEngine, email_sender: Any) -> AsyncIterator[Real]:
    """The ``real`` fixture of ``tests/conftest.py``: an EU app with the real verifiers."""

    from tests.conftest import make_settings  # the fixture module imports this one lazily

    parts: dict[str, Any] = {"apple": AppleEndpoints(), "jwks": JwksServer()}
    parts["apple"].subject = SUBJECT
    settings = make_settings(
        **{
            **APPLE_SETTINGS,
            "feature_oauth": True,
            "oauth_google_client_id": GOOGLE_ANDROID_ID,
            "oauth_google_server_client_id": GOOGLE_SERVER_ID,
        }
    )
    app = create_app(
        settings, email_sender=email_sender, oauth_transport=httpx.MockTransport(router(parts))
    )
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield Real(client, parts["apple"], parts["jwks"], engine, app)


def bearer(tokens: dict[str, Any]) -> dict[str, str]:
    return {"Authorization": f"Bearer {tokens['access_token']}"}
