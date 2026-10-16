"""Append-only change journal consumed by ``GET /v1/sync/pull``."""

from __future__ import annotations

import uuid
from typing import Literal

from sqlalchemy import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import SyncChange

Entity = Literal["profile", "medication", "schedule", "dose_event"]
Op = Literal["upsert", "delete"]


async def record_change(
    session: AsyncSession, user_id: uuid.UUID, entity: Entity, entity_id: uuid.UUID, op: Op
) -> None:
    """Journal one applied change; must run in the same transaction as the change."""
    await session.execute(
        insert(SyncChange).values(user_id=user_id, entity=entity, entity_id=entity_id, op=op)
    )


async def record_changes(
    session: AsyncSession,
    user_id: uuid.UUID,
    entity: Entity,
    entity_ids: list[uuid.UUID],
    op: Op,
) -> None:
    if entity_ids:
        await session.execute(
            insert(SyncChange),
            [
                {"user_id": user_id, "entity": entity, "entity_id": eid, "op": op}
                for eid in entity_ids
            ],
        )
