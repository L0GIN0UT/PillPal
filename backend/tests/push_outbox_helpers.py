"""Direct inserts into ``push_outbox`` for the push suites (the services under test are the
senders and the delivery job; enqueueing has its own tests)."""

from __future__ import annotations

import json
import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import User


async def token_id_of(engine: AsyncEngine, user: User, device: str | None = None) -> uuid.UUID:
    sql = "SELECT id FROM push_tokens WHERE user_id = :u"
    params: dict[str, Any] = {"u": uuid.UUID(user.id)}
    if device:
        sql += " AND device_id = :d"
        params["d"] = device
    async with engine.connect() as conn:
        return (await conn.execute(text(sql + " LIMIT 1"), params)).scalar_one()  # type: ignore[no-any-return]


async def insert_outbox(
    engine: AsyncEngine,
    recipient: User,
    profile_id: str,
    *,
    medication_id: str | None = None,
    kind: str = "missed",
    device: str | None = None,
    created_at: datetime | None = None,
    next_attempt_at: datetime | None = None,
    attempts: int = 0,
    dedupe: str | None = None,
    grant_id: str | None = None,
    payload_override: dict[str, Any] | None = None,
) -> int:
    """A pending row for the recipient's token; the recipient must have registered one."""
    token_id = await token_id_of(engine, recipient, device)
    alert_id = str(uuid.uuid4())
    payload: dict[str, Any] = {"v": 1, "t": kind, "p": profile_id}
    if kind in ("missed", "resolved"):
        payload["a"] = alert_id
        if medication_id:
            payload["m"] = medication_id
    else:
        payload["g"] = grant_id or alert_id
    if payload_override is not None:
        payload = payload_override
    async with engine.begin() as conn:
        row = await conn.execute(
            text(
                "INSERT INTO push_outbox (push_token_id, recipient_user_id, subject_profile_id, "
                "subject_medication_id, kind, dedupe_key, payload, attempts, created_at, "
                "next_attempt_at) VALUES (:tid, :u, :p, :m, :kind, :dedupe, "
                "CAST(:payload AS jsonb), :attempts, COALESCE(:created, now()), "
                "COALESCE(:next, now())) RETURNING id"
            ),
            {
                "tid": token_id,
                "u": uuid.UUID(recipient.id),
                "p": uuid.UUID(profile_id),
                "m": uuid.UUID(medication_id) if medication_id else None,
                "kind": kind,
                "dedupe": dedupe or f"{kind}:{alert_id}:{token_id}",
                "payload": json.dumps(payload),
                "attempts": attempts,
                "created": created_at,
                "next": next_attempt_at,
            },
        )
        return int(row.scalar_one())


# --- delivery fixtures ---------------------------------------------------------------------

from collections.abc import Callable  # noqa: E402

from httpx import AsyncClient  # noqa: E402
from redis.asyncio import Redis  # noqa: E402
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker  # noqa: E402

from app.config import Settings  # noqa: E402
from app.push.base import PushProvider, PushSender  # noqa: E402
from app.push.fake import FakePushSender  # noqa: E402
from app.services.push_delivery import DeliveryReport, deliver_pending  # noqa: E402
from tests.helpers import register  # noqa: E402
from tests.push_helpers import put_token, rows  # noqa: E402


def fake_senders() -> dict[PushProvider, FakePushSender]:
    return {
        "fcm": FakePushSender("fcm"),
        "apns": FakePushSender("apns"),
        "rustore": FakePushSender("rustore"),
    }


async def deliver(
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    senders: dict[PushProvider, FakePushSender] | dict[PushProvider, PushSender],
    now: Callable[[], datetime],
    redis: Redis | None = None,
) -> DeliveryReport:
    return await deliver_pending(maker, settings, senders, now, redis)  # type: ignore[arg-type]


async def outbox_rows(engine: AsyncEngine) -> list[Any]:
    return await rows(
        engine,
        "SELECT id, kind, status, attempts, next_attempt_at, sent_at, last_error_code, "
        "payload, subject_profile_id, recipient_user_id FROM push_outbox ORDER BY id",
    )


async def queued_for_new_user(
    client: AsyncClient, engine: AsyncEngine, n: int = 1
) -> tuple[User, list[int]]:
    """A new user with a token on ``dev-1`` and ``n`` pending pushes about their own profile."""
    user = await register(client)
    await put_token(client, user, "dev-1")
    return user, [await insert_outbox(engine, user, user.self_profile_id) for _ in range(n)]
