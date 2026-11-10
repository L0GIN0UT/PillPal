"""Helpers of the promo suites (ADR 0018 sections 3 and 4): codes inserted with SQL, redeem."""

from __future__ import annotations

import base64
import hashlib
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from httpx import AsyncClient, Response
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.domain.promo import code_digest, generate_code
from tests.grace_helpers import app_of
from tests.helpers import User

KEY = bytes((i * 7 + 3) % 256 for i in range(32))
KEY_B64 = base64.b64encode(KEY).decode()
OTHER_KEY = bytes((i * 11 + 5) % 256 for i in range(32))
URL = "/v1/me/promo/redeem"
# Well-formed (only alphabet symbols) and not the code of any stored promo.
UNKNOWN_CODE = "ABCDEFGHJKMNPQRSTUVW"
INVALID = {"error": {"code": "invalid_promo_code", "message": "This promo code cannot be used"}}


@dataclass(frozen=True)
class Promo:
    id: uuid.UUID
    code: str  # normalised, as the operator's tool would print it ungrouped


async def insert_code(
    engine: AsyncEngine,
    *,
    kind: str = "ads_removed",
    max_activations: int = 1,
    activations: int = 0,
    grant_days: int | None = None,
    expires_at: datetime | None = None,
    disabled_at: datetime | None = None,
    label: str = "synthetic-campaign",
    key: bytes = KEY,
) -> Promo:
    code, code_id = generate_code(20), uuid.uuid4()
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO promo_codes (id, code_digest, label, kind, grant_days, "
                "max_activations, activations, expires_at, disabled_at) VALUES (:id, :d, :l, :k, "
                ":g, :m, :a, :e, :x)"
            ),
            {
                "id": code_id,
                "d": code_digest(key, code),
                "l": label,
                "k": kind,
                "g": grant_days,
                "m": max_activations,
                "a": activations,
                "e": expires_at,
                "x": disabled_at,
            },
        )
    return Promo(code_id, code)


async def insert_redemption(
    engine: AsyncEngine, promo: Promo, user_id: str, entitlement_id: uuid.UUID
) -> None:
    """A redemption row for an entitlement that already exists (the activation is not counted)."""
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO promo_redemptions (code_id, user_id, entitlement_id) "
                "VALUES (:c, :u, :e)"
            ),
            {"c": promo.id, "u": uuid.UUID(user_id), "e": entitlement_id},
        )


async def redeem(
    client: AsyncClient, user: User, code: str, headers: dict[str, str] | None = None
) -> Response:
    return await client.post(URL, json={"code": code}, headers=headers or user.headers)


async def entitlements_of(engine: AsyncEngine, user: User) -> list[dict[str, Any]]:
    return await table_rows(
        engine,
        "SELECT id, kind, source, source_ref, granted_at, expires_at, revoked_at "
        "FROM entitlements WHERE user_id = :u ORDER BY granted_at",
        u=uuid.UUID(user.id),
    )


async def redemptions_of(engine: AsyncEngine, promo: Promo) -> list[dict[str, Any]]:
    return await table_rows(
        engine, "SELECT * FROM promo_redemptions WHERE code_id = :c", c=promo.id
    )


def redis_of(client: AsyncClient) -> Redis:
    redis: Redis = app_of(client).state.redis
    return redis


def hours(count: float) -> timedelta:
    return timedelta(hours=count)


def now_utc() -> datetime:
    return datetime.now(UTC)


def redis_key(kind: str, subject: str) -> str:
    """The Redis key ``app.services.promo_guard`` uses for ``kind`` and a user id or address."""
    from app.services.promo_guard import bucket_key

    return bucket_key(kind, subject)


async def activations_of(engine: AsyncEngine, promo: Promo) -> int:
    async with engine.connect() as conn:
        return int(
            (
                await conn.execute(
                    text("SELECT activations FROM promo_codes WHERE id = :i"), {"i": promo.id}
                )
            ).scalar_one()
        )


async def table_rows(engine: AsyncEngine, sql: str, **params: Any) -> list[dict[str, Any]]:
    async with engine.connect() as conn:
        return [dict(r) for r in (await conn.execute(text(sql), params)).mappings()]


def digest_text(code: str) -> str:
    return code_digest(KEY, code)


def sha(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()
