"""Shared fixtures of the relative-push suites: a world with an owner, an editor and a viewer."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import User, link_accounts, register
from tests.sync_helpers import (
    make_event,
    make_medication,
    make_schedule,
)


def at(seconds: int = 5) -> str:
    """A client timestamp newer than anything the server stored a moment ago."""
    return (datetime.now(UTC) + timedelta(seconds=seconds)).isoformat()


def m(
    entity: str, op: str, id_: str, data: dict[str, Any] | None = None, seconds: int = 5
) -> dict[str, Any]:
    return {"entity": entity, "op": op, "id": id_, "data": data, "client_updated_at": at(seconds)}


def med(profile_id: str, **overrides: Any) -> dict[str, Any]:
    return {"profile_id": profile_id, "name": "Edited by relative", "tz_mode": "local"} | overrides


@dataclass
class Level:
    medication: str
    schedule: str
    event: str


@dataclass
class World:
    owner: User
    editor: User
    viewer: User
    levels: dict[str, Level]

    @property
    def pid(self) -> str:
        return self.owner.self_profile_id


async def world(client: AsyncClient) -> World:
    owner, editor, viewer = await register(client), await register(client), await register(client)
    await link_accounts(client, owner, editor, "editor")
    await link_accounts(client, owner, viewer, "viewer")
    levels: dict[str, Level] = {}
    for privacy in ("shared", "anonymous", "hidden"):
        mid = await make_medication(client, owner, owner.self_profile_id, privacy)
        levels[privacy] = Level(
            mid, await make_schedule(client, owner, mid), await make_event(client, owner, mid)
        )
    return World(owner, editor, viewer, levels)


async def journal_scope(engine: AsyncEngine, entity_id: str) -> set[str]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT profile_id FROM sync_changes WHERE entity_id = :i"), {"i": entity_id}
        )
        return {str(r[0]) for r in rows}
