"""Lock order: journal lock before row locks (accept_invite vs ``DELETE /v1/me``, ADR 0010)."""

from __future__ import annotations

import asyncio

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.grace_helpers import request_deletion
from tests.helpers import accept_invite, create_invite, register, token_of

_WAITING_ON_ADVISORY = "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted"


async def _wait_until_an_advisory_lock_is_awaited(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        for _ in range(200):
            if (await conn.execute(text(_WAITING_ON_ADVISORY))).scalar_one():
                return
            await asyncio.sleep(0.02)
    raise AssertionError("accept never waited for the owner's journal lock")


async def test_accept_waits_for_the_journal_lock_without_holding_the_invite_row(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    """The request holds the journal lock and then updates the invite: that must not block.

    With the old order (invite row first, journal lock second) this deadlocks (40P01).
    """
    owner = await register(client)
    guest = await register(client)
    token = token_of(await create_invite(client, owner))

    async with engine.connect() as conn:
        await conn.execute(
            text("SELECT pg_advisory_xact_lock(hashtextextended(:owner, 0))"),
            {"owner": owner.id},
        )
        accepting = asyncio.create_task(accept_invite(client, guest, token))
        await _wait_until_an_advisory_lock_is_awaited(engine)
        await asyncio.wait_for(
            conn.execute(text("UPDATE invites SET revoked_at = now() WHERE consumed_at IS NULL")),
            timeout=5,
        )
        await conn.commit()

    resp = await asyncio.wait_for(accepting, timeout=10)
    assert resp.status_code == 404, resp.text  # revoked while it waited: re-checked after the lock


@pytest.mark.parametrize("round_", range(3))
async def test_accepting_while_the_owner_requests_deletion_never_fails_with_a_500(
    client: AsyncClient, engine: AsyncEngine, round_: int
) -> None:
    owner = await register(client)
    guest = await register(client)
    token = token_of(await create_invite(client, owner))

    accepted, deleted = await asyncio.gather(
        accept_invite(client, guest, token), request_deletion(client, owner)
    )

    assert deleted.status_code == 204
    assert accepted.status_code in (201, 404), accepted.text
