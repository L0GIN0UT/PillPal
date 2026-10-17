"""Retention of push data: outbox rows (sent 24 h, all 7 days) and stale tokens (270 days)."""

from __future__ import annotations

import uuid
from datetime import timedelta

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.grace_helpers import count, in_days, run_retention
from tests.helpers import register
from tests.push_helpers import put_token
from tests.push_outbox_helpers import insert_outbox


async def _mark(engine: AsyncEngine, row_id: int, status: str) -> None:
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE push_outbox SET status = :s, "
                "sent_at = CASE WHEN :s = 'sent' THEN now() END WHERE id = :i"
            ),
            {"s": status, "i": row_id},
        )


async def test_sent_rows_go_after_a_day_the_rest_after_a_week(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await put_token(client, user)
    sent = await insert_outbox(engine, user, user.self_profile_id)
    dropped = await insert_outbox(engine, user, user.self_profile_id)
    pending = await insert_outbox(engine, user, user.self_profile_id)
    await _mark(engine, sent, "sent")
    await _mark(engine, dropped, "dropped")

    assert (await run_retention(client, in_days(0) + timedelta(hours=23))).push_outbox_deleted == 0
    report = await run_retention(client, in_days(0) + timedelta(hours=25))
    assert report.push_outbox_deleted == 1
    left = {
        r for r in (sent, dropped, pending) if await count(engine, "push_outbox", "id = :i", i=r)
    }
    assert left == {dropped, pending}

    assert (await run_retention(client, in_days(6))).push_outbox_deleted == 0
    assert (await run_retention(client, in_days(8))).push_outbox_deleted == 2
    assert await count(engine, "push_outbox") == 0
    assert (await run_retention(client, in_days(8))).push_outbox_deleted == 0  # idempotent


async def test_tokens_without_success_for_270_days_are_deleted(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await put_token(client, user, "silent")
    await put_token(client, user, "working")
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE push_tokens SET last_success_at = now() + interval '100 days' "
                "WHERE device_id = 'working'"
            )
        )
    assert (await run_retention(client, in_days(269))).push_tokens_deleted == 0
    report = await run_retention(client, in_days(271))
    assert report.push_tokens_deleted == 1
    assert await count(engine, "push_tokens", "device_id = 'silent'") == 0
    assert await count(engine, "push_tokens", "device_id = 'working'") == 1
    # 100 + 270 days after now the working token is stale as well.
    assert (await run_retention(client, in_days(371))).push_tokens_deleted == 1


async def test_a_deleted_token_takes_its_pending_rows_along(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await put_token(client, user)
    await insert_outbox(engine, user, user.self_profile_id)
    await run_retention(client, in_days(271))
    assert await count(engine, "push_tokens") == 0
    assert await count(engine, "push_outbox") == 0
    assert uuid.UUID(user.id)
