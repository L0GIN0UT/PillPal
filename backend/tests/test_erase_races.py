"""Races around the erase transaction, made deterministic by holding it open (ADR 0010 §5)."""

from __future__ import annotations

import asyncio
import uuid
from datetime import UTC, datetime, timedelta

from httpx import AsyncClient
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from app.db.models import User as UserRow
from app.services.erasure import erase_account
from tests.grace_helpers import count, pending_login, request_deletion, restore
from tests.helpers import register
from tests.ward_helpers import make_ward, profile_row

_WAITING = "SELECT count(*) FROM pg_locks WHERE NOT granted"


async def _wait_for_a_blocked_lock(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        for _ in range(250):
            if (await conn.execute(text(_WAITING))).scalar_one():
                return
            await asyncio.sleep(0.02)
    raise AssertionError("nothing ever waited for a lock")


async def _erase_without_committing(session: AsyncSession, user_id: str) -> None:
    """What the job does inside its transaction, minus the commit."""
    await session.scalar(
        select(UserRow.id).where(UserRow.id == uuid.UUID(user_id)).with_for_update(key_share=True)
    )
    await erase_account(
        session,
        uuid.UUID(user_id),
        now=datetime.now(UTC) + timedelta(days=31),
        managed_archive_retention_days=365,
    )


async def test_a_restore_waiting_on_the_row_held_by_the_erase_finds_the_account_gone(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    assert (await request_deletion(client, user)).status_code == 204
    ticket, code = await pending_login(client, user)

    async with AsyncSession(engine) as erasing:
        await _erase_without_committing(erasing, user.id)
        restoring = asyncio.create_task(restore(client, ticket, code))
        await _wait_for_a_blocked_lock(engine)
        await erasing.commit()

    resp = await asyncio.wait_for(restoring, timeout=10)
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_token"
    assert await count(engine, "users", "id = :id", id=user.id) == 0


async def test_an_heir_requesting_deletion_while_the_ward_is_handed_over(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client)
    assert (await request_deletion(client, ward.owner)).status_code == 204

    async with AsyncSession(engine) as erasing:
        await _erase_without_committing(erasing, ward.owner.id)  # holds the heir's journal lock
        heir_deleting = asyncio.create_task(request_deletion(client, ward.first))
        await _wait_for_a_blocked_lock(engine)
        await erasing.commit()

    resp = await asyncio.wait_for(heir_deleting, timeout=10)
    assert resp.status_code == 204  # no deadlock, no 500
    row = await profile_row(engine, ward.profile_id)
    assert row["owner_user_id"] == ward.first.id  # the hand-over stands
    assert row["archive_reason"] == "owner_erased"  # and is not re-archived as pending
    assert row["archived_at"] is not None
