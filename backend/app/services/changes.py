"""Append-only change journal consumed by ``GET /v1/sync/pull``.

``seq`` comes from a sequence, so it is allocated at INSERT time while rows
become visible at COMMIT time. If two transactions of one user interleave
(T1 gets seq 7, T2 gets seq 8 and commits first), a pull between the commits
returns 8 and the client's cursor jumps over 7 for ever. Every transaction
that journals therefore takes a per-user advisory lock *before* its first
journal insert and holds it until commit (:func:`lock_journal`): per user,
seq order equals commit order. Different users never wait for each other.
"""

from __future__ import annotations

import uuid
from typing import Literal

from sqlalchemy import func, insert, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import SyncChange

Entity = Literal["profile", "medication", "schedule", "dose_event"]
Op = Literal["upsert", "delete"]


async def lock_journal(session: AsyncSession, user_id: uuid.UUID) -> None:
    """Serialize journal writers of one user until the transaction ends.

    Call it in the top-level transaction (a lock taken inside a SAVEPOINT is
    released when that savepoint rolls back) before any journal insert and
    before taking row locks, so all writers lock in the same order.
    Re-entrant within a transaction.
    """
    key = func.hashtextextended(str(user_id), 0)
    await session.execute(select(func.pg_advisory_xact_lock(key)))


async def record_change(
    session: AsyncSession, user_id: uuid.UUID, entity: Entity, entity_id: uuid.UUID, op: Op
) -> None:
    """Journal one applied change in the change's transaction (after :func:`lock_journal`)."""
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
