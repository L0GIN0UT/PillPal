"""Helpers of the server-pause suites (ADR 0016 section 5): withdraw and give health consent."""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime
from typing import Any

from httpx import AsyncClient
from sqlalchemy import event, select, text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.db.models import Profile
from app.services.consent_pause import profile_consented
from tests.helpers import User

Maker = async_sessionmaker[AsyncSession]


async def withdraw_health(engine: AsyncEngine, user: User) -> None:
    """The record is withdrawn, as a deletion request does (ADR 0016 section 4)."""
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE consents SET withdrawn_at = now() "
                "WHERE user_id = :u AND kind = 'health_data' AND withdrawn_at IS NULL"
            ),
            {"u": uuid.UUID(user.id)},
        )


async def drop_all_consents(engine: AsyncEngine) -> None:
    """Every account as it was before consent records existed (a field-test account)."""
    async with engine.begin() as conn:
        await conn.execute(text("DELETE FROM consents"))


async def reaccept(client: AsyncClient, user: User) -> None:
    resp = await client.post(
        "/v1/me/consents", json={"kind": "health_data", "version": 1}, headers=user.headers
    )
    assert resp.status_code == 201, resp.text


async def set_accepted_at(engine: AsyncEngine, user: User, when: datetime) -> None:
    """Move the active health-data record in time (the detector reads it against its clock)."""
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE consents SET accepted_at = :t "
                "WHERE user_id = :u AND kind = 'health_data' AND withdrawn_at IS NULL"
            ),
            {"u": uuid.UUID(user.id), "t": when},
        )


async def missing_of(client: AsyncClient, user: User) -> list[str]:
    resp = await client.get("/v1/me/consents", headers=user.headers)
    return list(resp.json()["missing"])


async def paused_profiles(maker: Maker, *profile_ids: str) -> set[str]:
    """The given profiles that the server treats as paused."""
    ids = [uuid.UUID(p) for p in profile_ids]
    async with maker() as session:
        live = set(
            await session.scalars(
                select(Profile.id).where(Profile.id.in_(ids), profile_consented())
            )
        )
    return {str(i) for i in ids if i not in live}


@contextmanager
def count_statements(engine: AsyncEngine) -> Iterator[list[str]]:
    seen: list[str] = []

    def record(conn: Any, cursor: Any, statement: str, *rest: Any) -> None:
        seen.append(statement)

    event.listen(engine.sync_engine, "before_cursor_execute", record)
    try:
        yield seen
    finally:
        event.remove(engine.sync_engine, "before_cursor_execute", record)
