"""Helpers of the OAuth suites (ADR 0017): nonce, fake assertions, sign-in, sign-up, Redis peeks."""

from __future__ import annotations

import hashlib
import json
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

from httpx import AsyncClient, Response
from redis.asyncio import Redis

from app.config import Settings
from app.oauth.fake import nonce_digest
from app.services.oauth_state import OAuthState, SignupTicket
from tests.conftest import TEST_REDIS_URL

SUBJECT = "vk-subject-1"
CONSENTS = [
    {"kind": "health_data", "version": 1},
    {"kind": "terms", "version": 1},
    {"kind": "privacy", "version": 1},
]


def assertion(
    sub: str,
    *,
    nonce: str,
    email: str | None = None,
    verified: bool = True,
    jti: str | None = None,
    exp: float | None = None,
    fail: str | None = None,
) -> str:
    """What the fake provider accepts as an ID token or code."""
    claims: dict[str, Any] = {
        "sub": sub,
        "nonce": nonce_digest(nonce),
        "jti": jti or uuid.uuid4().hex,
    }
    if email is not None:
        claims["email"] = email
        claims["email_verified"] = verified
    if exp is not None:
        claims["exp"] = exp
    if fail is not None:
        claims["fail"] = fail
    return json.dumps(claims)


async def new_nonce(
    client: AsyncClient, purpose: str = "sign_in", headers: dict[str, str] | None = None
) -> str:
    resp = await client.post("/v1/auth/oauth/nonce", json={"purpose": purpose}, headers=headers)
    assert resp.status_code == 200, resp.text
    return str(resp.json()["nonce"])


async def sign_in(
    client: AsyncClient,
    provider: str = "vk_id",
    sub: str = SUBJECT,
    *,
    email: str | None = None,
    verified: bool = True,
    platform: str = "android",
    purpose: str = "sign_in",
    nonce: str | None = None,
    token_nonce: str | None = None,
    jti: str | None = None,
    exp: float | None = None,
    fail: str | None = None,
    headers: dict[str, str] | None = None,
) -> Response:
    """``POST /v1/auth/oauth/{provider}/sign-in`` with a fresh server nonce unless one is given."""
    nonce = nonce or await new_nonce(client, purpose)
    token = assertion(
        sub,
        nonce=token_nonce or nonce,
        email=email,
        verified=verified,
        jti=jti,
        exp=exp,
        fail=fail,
    )
    body = {"platform": platform, "assertion": token, "nonce": nonce}
    return await client.post(f"/v1/auth/oauth/{provider}/sign-in", json=body, headers=headers)


def ticket_of(resp: Response) -> str:
    assert resp.status_code == 409, resp.text
    error = resp.json()["error"]
    assert error["code"] == "oauth_signup_required", resp.text
    return str(error["details"]["signup_ticket"])


async def sign_up(
    client: AsyncClient,
    ticket: str,
    *,
    region: str = "ru",
    headers: dict[str, str] | None = None,
    **extra: Any,
) -> Response:
    body = {"signup_ticket": ticket, "region": region, "timezone": "Europe/Samara", **extra}
    return await client.post("/v1/auth/oauth/sign-up", json=body, headers=headers)


async def oauth_account(
    client: AsyncClient,
    provider: str = "vk_id",
    sub: str = SUBJECT,
    email: str = "oauth-user@example.com",
    platform: str = "android",
    region: str = "ru",
) -> dict[str, Any]:
    """Sign in, sign up with a provider-verified address and return the token pair."""
    ticket = ticket_of(
        await sign_in(client, provider, sub, email=email, platform=platform, verified=True)
    )
    resp = await sign_up(client, ticket, region=region, consents=CONSENTS)
    assert resp.status_code == 201, resp.text
    return dict(resp.json())


def bearer(tokens: dict[str, Any]) -> dict[str, str]:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


@asynccontextmanager
async def redis_client() -> AsyncIterator[Redis]:
    redis: Redis = Redis.from_url(TEST_REDIS_URL)
    try:
        yield redis
    finally:
        await redis.aclose()


async def redis_keys() -> list[str]:
    async with redis_client() as redis:
        return sorted([k.decode() async for k in redis.scan_iter("*")])


def ticket_key(ticket: str) -> str:
    return "ot:" + hashlib.sha256(ticket.encode()).hexdigest()


async def plant_ticket(settings: Settings, **overrides: Any) -> str:
    """A live sign-up ticket with chosen contents (another region, another platform, ...)."""
    values: dict[str, Any] = {
        "provider": "vk_id",
        "subject": "planted-subject",
        "email": "planted@example.com",
        "email_verified": True,
        "region": "ru",
        "platform": "android",
    }
    values.update(overrides)
    async with redis_client() as redis:
        return await OAuthState(redis, settings).issue_ticket(SignupTicket(**values))
