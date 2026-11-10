"""Helpers of the identity and re-auth suites (ADR 0017 sections 6 and 8)."""

from __future__ import annotations

import time
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

from httpx import AsyncClient, Response
from redis.asyncio import Redis

from app.config import Settings
from app.ratelimit import RateLimiter
from tests.grace_helpers import app_of
from tests.helpers import DEFAULT_PASSWORD
from tests.oauth_helpers import assertion, new_nonce

IDENTITIES_URL = "/v1/me/identities"
PASSWORD_PROOF: dict[str, Any] = {"password": DEFAULT_PASSWORD}


async def reauth_proof(
    client: AsyncClient,
    headers: dict[str, str],
    provider: str,
    sub: str,
    *,
    age_seconds: float = 0,
    purpose: str = "reauth",
    jti: str | None = None,
    platform: str = "android",
) -> dict[str, Any]:
    """The reauth form: a fresh assertion of an identity (``age_seconds`` old)."""
    nonce = await new_nonce(client, purpose, headers)
    token = assertion(sub, nonce=nonce, jti=jti, iat=time.time() - age_seconds)
    return {
        "reauth": {"provider": provider, "platform": platform, "assertion": token, "nonce": nonce}
    }


async def link_body(
    client: AsyncClient,
    headers: dict[str, str],
    provider: str,
    sub: str,
    proof: dict[str, Any],
    *,
    purpose: str = "link",
    jti: str | None = None,
    email: str | None = None,
    platform: str = "android",
    fail: str | None = None,
) -> dict[str, Any]:
    nonce = await new_nonce(client, purpose, headers)
    token = assertion(
        sub, nonce=nonce, jti=jti, email=email, verified=True, iat=time.time(), fail=fail
    )
    return {"provider": provider, "platform": platform, "assertion": token, "nonce": nonce, **proof}


async def link(
    client: AsyncClient,
    headers: dict[str, str],
    provider: str,
    sub: str,
    proof: dict[str, Any] | None = None,
    **kwargs: Any,
) -> Response:
    body = await link_body(client, headers, provider, sub, proof or PASSWORD_PROOF, **kwargs)
    return await client.post(IDENTITIES_URL, json=body, headers=headers)


async def unlink(
    client: AsyncClient, headers: dict[str, str], identity_id: str | uuid.UUID, proof: Any = None
) -> Response:
    return await client.request(
        "DELETE",
        f"{IDENTITIES_URL}/{identity_id}",
        json=PASSWORD_PROOF if proof is None else proof,
        headers=headers,
    )


async def identities(client: AsyncClient, headers: dict[str, str]) -> list[dict[str, Any]]:
    resp = await client.get(IDENTITIES_URL, headers=headers)
    assert resp.status_code == 200, resp.text
    return list(resp.json()["items"])


@asynccontextmanager
async def limiter_down(client: AsyncClient, settings: Settings) -> AsyncIterator[None]:
    """The rate limiter cannot reach Redis (the rest of the app is untouched)."""
    app = app_of(client)
    live = app.state.rate_limiter
    dead: Redis = Redis.from_url(
        "redis://127.0.0.1:1/0", socket_connect_timeout=0.2, socket_timeout=0.2
    )
    app.state.rate_limiter = RateLimiter(dead, settings)
    try:
        yield
    finally:
        app.state.rate_limiter = live
        await dead.aclose()
