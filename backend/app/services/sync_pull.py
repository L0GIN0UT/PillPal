"""Sync pull and the server-state representation shared with push results (TZ §4.3).

Pull returns journal entries after a cursor. Each carries the entity's
*current* state plus its conflict key (``client_updated_at``,
``updated_by_device``, ``deleted_at``), so a client can merge it with the same
last-write-wins rule the server uses. Several journal rows of one entity in a
page collapse into one change, placed at the entity's *first* position in the
page: creation order is preserved, so parents come before their children.
"""

from __future__ import annotations

import uuid
from typing import Any

from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import DoseEvent, Medication, Profile, Schedule, SyncChange
from app.schemas.entities import (
    Change,
    DoseEventOut,
    EntityState,
    MedicationOut,
    ProfileOut,
    PullResponse,
    ScheduleOut,
)

SyncRow = Profile | Medication | Schedule
EntityKey = tuple[str, uuid.UUID]

_OUT_MODELS: dict[str, type[BaseModel]] = {
    "profile": ProfileOut,
    "medication": MedicationOut,
    "schedule": ScheduleOut,
}


def entity_state(entity: str, row: SyncRow | DoseEvent) -> EntityState:
    """Current state of ``row``; tombstones have ``data=None`` but keep the key."""
    if isinstance(row, DoseEvent):
        data = DoseEventOut.model_validate(row).model_dump(mode="json")
        return EntityState(
            op="upsert", data=data, client_updated_at=None, updated_by_device=None, deleted_at=None
        )
    deleted = row.deleted_at is not None
    return EntityState(
        op="delete" if deleted else "upsert",
        data=None if deleted else _OUT_MODELS[entity].model_validate(row).model_dump(mode="json"),
        client_updated_at=row.client_updated_at,
        updated_by_device=row.updated_by_device,
        deleted_at=row.deleted_at,
    )


async def pull_changes(
    session: AsyncSession, user_id: uuid.UUID, cursor: int, limit: int
) -> PullResponse:
    rows = (
        await session.execute(
            select(SyncChange.seq, SyncChange.entity, SyncChange.entity_id)
            .where(SyncChange.user_id == user_id, SyncChange.seq > cursor)
            .order_by(SyncChange.seq)
            .limit(limit + 1)
        )
    ).all()
    has_more = len(rows) > limit
    page = rows[:limit]
    if not page:
        return PullResponse(changes=[], next_cursor=cursor, has_more=False)

    first: dict[EntityKey, int] = {}
    latest: dict[EntityKey, int] = {}
    for seq, entity, entity_id in page:
        first.setdefault((entity, entity_id), seq)
        latest[(entity, entity_id)] = seq
    states = await _current_states(session, user_id, list(first))

    changes: list[Change] = []
    for key in sorted(first, key=first.__getitem__):
        state = states.get(key)
        if state is None:  # pragma: no cover - journal rows always have an entity
            continue
        changes.append(Change(seq=latest[key], entity=key[0], id=key[1], **dict(state)))
    return PullResponse(changes=changes, next_cursor=page[-1][0], has_more=has_more)


async def _current_states(
    session: AsyncSession, user_id: uuid.UUID, keys: list[EntityKey]
) -> dict[EntityKey, EntityState]:
    by_entity: dict[str, list[uuid.UUID]] = {}
    for entity, entity_id in keys:
        by_entity.setdefault(entity, []).append(entity_id)
    owner = Profile.owner_user_id == user_id
    queries: dict[str, Any] = {
        "profile": select(Profile).where(owner),
        "medication": select(Medication)
        .join(Profile, Profile.id == Medication.profile_id)
        .where(owner),
        "schedule": select(Schedule)
        .join(Medication, Medication.id == Schedule.medication_id)
        .join(Profile, Profile.id == Medication.profile_id)
        .where(owner),
        "dose_event": select(DoseEvent)
        .join(Profile, Profile.id == DoseEvent.profile_id)
        .where(owner),
    }
    models: dict[str, Any] = {
        "profile": Profile,
        "medication": Medication,
        "schedule": Schedule,
        "dose_event": DoseEvent,
    }
    out: dict[EntityKey, EntityState] = {}
    for entity, ids in by_entity.items():
        stmt = queries[entity].where(models[entity].id.in_(ids))
        for row in await session.scalars(stmt):
            out[(entity, row.id)] = entity_state(entity, row)
    return out
