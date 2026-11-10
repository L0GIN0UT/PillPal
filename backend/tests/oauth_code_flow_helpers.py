"""Fixtures and helpers of the VK ID and Yandex ID API suites (milestone 5.9): an RU app on the
shared test database with the real code verifiers, both providers served by ``MockTransport``."""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Any

import httpx
from httpx import ASGITransport, AsyncClient, Response

from app.config import Settings
from app.main import create_app
from app.oauth.base import VerifiedIdentity
from app.oauth.registry import ProviderRegistry
from tests.helpers import last_code
from tests.oauth_code_helpers import (
    CODE,
    DEVICE_ID,
    NOW,
    STATE,
    VERIFIER,
    CodeEndpoints,
    settings_for,
)
from tests.oauth_helpers import CONSENTS, new_nonce, sign_up, ticket_of

PROVIDERS = ("vk_id", "yandex_id")


async def exchange(name: str, settings: Settings) -> VerifiedIdentity:
    """One verification of ``name`` against the scripted endpoints (no database)."""
    registry = ProviderRegistry(settings, transport=CodeEndpoints().transport())
    try:
        provider = registry.get(name, "android")
        assert provider is not None
        return await provider.verify(
            CODE,
            nonce=STATE,
            platform="android",
            code_verifier=VERIFIER,
            device_id=DEVICE_ID,
            now=NOW,
        )
    finally:
        await registry.aclose()


@dataclass
class Codes:
    """An RU app with VK ID and Yandex ID; ``endpoints`` scripts what the providers answer."""

    client: AsyncClient
    endpoints: CodeEndpoints
    app: Any

    def body(
        self, name: str, nonce: str, *, code: str | None = None, **extra: Any
    ) -> dict[str, Any]:
        """A request body; a fresh code each time unless one is given (a code is single use)."""
        body: dict[str, Any] = {
            "platform": "android",
            "assertion": code or f"code.{uuid.uuid4().hex}",
            "nonce": nonce,
            "code_verifier": VERIFIER,
        }
        if name == "vk_id":
            body["device_id"] = DEVICE_ID
        body.update(extra)
        return body

    async def account(
        self, name: str = "vk_id", email: str = "code-user@example.com"
    ) -> dict[str, Any]:
        """Sign in (a 409 with a ticket), start sign-up with a typed address, verify the mailed
        code with the pending token; returns the token pair. Neither provider verifies the
        address, so this is the only way in."""
        ticket = ticket_of(await self.sign_in(name))
        started = await sign_up(self.client, ticket, email=email, consents=CONSENTS)
        assert started.status_code == 202, started.text
        verified = await self.client.post(
            "/v1/auth/verify-email",
            json={
                "email": email,
                "code": last_code(self.client, email),
                "pending_token": started.json()["pending_token"],
            },
        )
        assert verified.status_code == 200, verified.text
        return dict(verified.json())

    async def sign_in(
        self,
        name: str = "vk_id",
        *,
        purpose: str = "sign_in",
        nonce: str | None = None,
        code: str | None = None,
        **extra: Any,
    ) -> Response:
        nonce = nonce or await new_nonce(self.client, purpose)
        return await self.client.post(
            f"/v1/auth/oauth/{name}/sign-in", json=self.body(name, nonce, code=code, **extra)
        )


@asynccontextmanager
async def codes_context(email_sender: Any, *, email: str | None = None) -> AsyncIterator[Codes]:
    endpoints = CodeEndpoints(email=email)
    app = create_app(
        settings_for(), email_sender=email_sender, oauth_transport=endpoints.transport()
    )
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            yield Codes(client, endpoints, app)


def error_code(resp: httpx.Response) -> str:
    return str(resp.json()["error"]["code"])
