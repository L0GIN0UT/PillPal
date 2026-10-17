"""Helpers of the push suites: token registration and direct reads of the push tables."""

from __future__ import annotations

import uuid
from typing import Any

from httpx import AsyncClient, Response
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import User

APNS_TOKEN = "ab" * 32


def fcm_token(n: int | str = 1) -> str:
    return f"fcm-token-{n}:APA91b_synthetic-{n}"


async def put_token(
    client: AsyncClient,
    user: User,
    device: str = "dev-1",
    *,
    provider: str = "fcm",
    token: str | None = None,
    apns_environment: str | None = None,
    **extra: Any,
) -> Response:
    body: dict[str, Any] = {"provider": provider, "token": token or fcm_token(device), **extra}
    if apns_environment is not None:
        body["apns_environment"] = apns_environment
    return await client.put("/v1/push-tokens/current", json=body, headers=user.device(device))


async def delete_token(client: AsyncClient, user: User, device: str = "dev-1") -> Response:
    return await client.delete("/v1/push-tokens/current", headers=user.device(device))


async def rows(engine: AsyncEngine, sql: str, **params: Any) -> list[Any]:
    async with engine.connect() as conn:
        return list((await conn.execute(text(sql), params)).all())


async def token_rows(engine: AsyncEngine, user: User | None = None) -> list[Any]:
    where = "WHERE user_id = :u" if user else ""
    params = {"u": uuid.UUID(user.id)} if user else {}
    return await rows(
        engine,
        f"SELECT id, user_id, device_id, provider, token, apns_environment FROM push_tokens "  # noqa: S608
        f"{where} ORDER BY created_at, device_id",
        **params,
    )
