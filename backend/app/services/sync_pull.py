"""Sync pull (TZ §4.3, ADR 0006 §2): journal rows after a cursor, as current entity states.

Each change carries the entity's *current* state plus its conflict key, so a client
merges it with the same last-write-wins rule the server uses. Several journal rows
of one entity in a page collapse into one change.

``POST /v1/sync/pull`` reads one page of several scopes (profiles) under one
REPEATABLE READ snapshot, so the scope list, the journal rows and the entity
states agree. Relatives get the privacy projection (``app.domain.privacy``);
hidden medications are filtered out of the journal read itself (``sync_rows``), so
hidden activity never moves a relative's cursor; the cursor is the newest row read.
``GET /v1/sync/pull`` (one cursor over the caller's own scopes) is the Phase 2
form, kept until the app switches.
"""

from __future__ import annotations

import uuid
from collections.abc import Collection, Mapping
from datetime import datetime
from typing import Any, cast

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.models import DoseEvent, Medication, Profile, Schedule, SyncChange
from app.domain.privacy import visible_last_seen
from app.schemas.sync import PullResponse, ScopedPullResponse, ScopeOut
from app.services.devices import touch_device_throttled
from app.services.sync_build import (
    EntityKey,
    GroupKey,
    Loaded,
    Window,
    build_changes,
    collapse,
    narrowing_candidates,
)
from app.services.sync_rows import creation_seqs, read_rows, readable_heads
from app.services.sync_scopes import ScopeInfo, live_scopes, owner_last_seen, tombstoned_scopes
from app.services.sync_state import entity_state

# --- entity states -----------------------------------------------------------------------------


async def _load_states(
    session: AsyncSession, groups: Collection[GroupKey], scope_ids: Collection[uuid.UUID]
) -> dict[EntityKey, Loaded]:
    """Current state of every entity in ``groups``; only rows inside ``scope_ids`` load."""
    by_entity: dict[str, list[uuid.UUID]] = {}
    for _, entity, entity_id in groups:
        by_entity.setdefault(entity, []).append(entity_id)
    scopes = list(scope_ids)
    out: dict[EntityKey, Loaded] = {}
    if ids := by_entity.get("profile"):
        stmt = select(Profile).where(Profile.id.in_(ids), Profile.id.in_(scopes))
        for profile in await session.scalars(stmt):
            out[("profile", profile.id)] = Loaded(entity_state("profile", profile), None)
    if ids := by_entity.get("medication"):
        med_stmt = select(Medication).where(
            Medication.id.in_(ids), Medication.profile_id.in_(scopes)
        )
        for med in await session.scalars(med_stmt):
            out[("medication", med.id)] = Loaded(entity_state("medication", med), med.privacy)
    for schedule, privacy in await _children(session, Schedule, by_entity, scopes):
        out[("schedule", schedule.id)] = Loaded(entity_state("schedule", schedule), privacy)
    for event, privacy in await _children(session, DoseEvent, by_entity, scopes):
        out[("dose_event", event.id)] = Loaded(entity_state("dose_event", event), privacy)
    return out


async def _children(
    session: AsyncSession,
    model: type[Schedule] | type[DoseEvent],
    by_entity: Mapping[str, list[uuid.UUID]],
    scope_ids: list[uuid.UUID],
) -> list[tuple[Any, str]]:
    """Schedules or dose events with the privacy of the medication they belong to."""
    entity = "schedule" if model is Schedule else "dose_event"
    ids = by_entity.get(entity)
    if not ids:
        return []
    stmt = (
        select(model, Medication.privacy)
        .join(Medication, Medication.id == model.medication_id)
        .where(model.id.in_(ids), Medication.profile_id.in_(list(scope_ids)))
    )
    return [(row, privacy) for row, privacy in await session.execute(stmt)]


# --- POST /v1/sync/pull ------------------------------------------------------------------------


def _scope_out(
    scope: ScopeInfo,
    cursors: Mapping[uuid.UUID, int],
    last_seen: Mapping[uuid.UUID, datetime],
    markers: Mapping[uuid.UUID, int],
) -> ScopeOut:
    cursor = cursors.get(scope.profile_id)
    marker = markers.get(scope.profile_id, 0)
    return ScopeOut(
        profile_id=scope.profile_id,
        role=scope.role,
        kind=cast(Any, scope.kind),
        # TODO(3.4): archiving is not built yet; these two are constants until it is.
        archived=False,
        archive_purge_after=None,
        owner_last_seen_at=visible_last_seen(scope.role, scope.kind, last_seen.get(scope.owner_id)),
        cursor=cursor,
        backfill_until=marker if cursor is not None and cursor < marker else None,
    )


async def pull_scoped(
    session: AsyncSession,
    settings: Settings,
    user_id: uuid.UUID,
    device_id: str,
    cursors: Mapping[uuid.UUID, int],
    limit: int,
    *,
    backfill_until: Mapping[uuid.UUID, int] | None = None,
) -> ScopedPullResponse:
    """One page for the requested scopes under a REPEATABLE READ snapshot."""
    await touch_device_throttled(session, settings, user_id, device_id)
    await session.commit()  # the isolation level can only be set on a fresh transaction
    await session.connection(execution_options={"isolation_level": "REPEATABLE READ"})
    try:
        return await _pull_page(session, user_id, cursors, limit, backfill_until or {})
    finally:
        await session.rollback()  # read-only: ends the snapshot


async def _backfill_markers(
    session: AsyncSession,
    scopes: Mapping[uuid.UUID, ScopeInfo],
    requested: Mapping[uuid.UUID, int],
    echoed: Mapping[uuid.UUID, int],
) -> dict[uuid.UUID, int]:
    """Where each projected scope's backfill ends; the client echoes it until its cursor is there.

    A pull from cursor 0 without a marker starts a backfill: it ends at the newest row the
    relative may read in this snapshot. A hostile client that echoes a smaller marker only
    narrows what is suppressed to what the grant (``granted_seq``) already allows it.
    """
    projected = {pid: echoed.get(pid, 0) for pid in requested if scopes[pid].projected}
    starting = [pid for pid, marker in projected.items() if marker == 0 and requested[pid] == 0]
    heads = await readable_heads(session, starting)
    return projected | {pid: heads.get(pid, 0) for pid in starting}


async def _pull_page(
    session: AsyncSession,
    user_id: uuid.UUID,
    cursors: Mapping[uuid.UUID, int],
    limit: int,
    echoed: Mapping[uuid.UUID, int],
) -> ScopedPullResponse:
    scopes = await live_scopes(session, user_id)
    unseen = {pid: cursor for pid, cursor in cursors.items() if pid not in scopes}
    scopes |= await tombstoned_scopes(session, user_id, unseen)
    requested = {pid: cursor for pid, cursor in cursors.items() if pid in scopes}
    rows = await read_rows(session, requested, [p for p in requested if scopes[p].projected], limit)
    page = rows[:limit]
    groups = collapse(page)
    states = await _load_states(session, groups, requested)
    markers = await _backfill_markers(session, scopes, requested, echoed)
    windows = {
        pid: Window(sent, max(scopes[pid].granted_seq, markers.get(pid, 0)))
        for pid, sent in requested.items()
    }
    created = await creation_seqs(session, narrowing_candidates(groups, states, scopes, windows))
    changes = build_changes(groups, states, scopes, windows, created)
    new_cursors = dict(requested)
    for seq, profile_id, *_ in page:
        new_cursors[profile_id] = max(new_cursors[profile_id], seq)
    last_seen = await owner_last_seen(session, list(scopes.values()))
    return ScopedPullResponse(
        scopes=[_scope_out(s, new_cursors, last_seen, markers) for s in scopes.values()],
        revoked=[pid for pid in cursors if pid not in scopes],
        changes=changes,
        has_more=len(rows) > limit,
    )


# --- GET /v1/sync/pull (Phase 2, one cursor over the caller's own scopes) ----------------------


async def pull_changes(
    session: AsyncSession, user_id: uuid.UUID, cursor: int, limit: int
) -> PullResponse:
    owned = select(Profile.id).where(Profile.owner_user_id == user_id)
    rows = (
        await session.execute(
            select(
                SyncChange.seq,
                SyncChange.profile_id,
                SyncChange.entity,
                SyncChange.entity_id,
                SyncChange.op,
                SyncChange.created_at,
            )
            .where(SyncChange.profile_id.in_(owned), SyncChange.seq > cursor)
            .order_by(SyncChange.seq)
            .limit(limit + 1)
        )
    ).all()
    page = rows[:limit]
    if not page:
        return PullResponse(changes=[], next_cursor=cursor, has_more=False)
    groups = collapse(list(page))
    scope_ids = {key[0] for key in groups}
    scopes = {pid: ScopeInfo(pid, "", user_id, "owner", 0) for pid in scope_ids}
    states = await _load_states(session, groups, scope_ids)
    windows = dict.fromkeys(scope_ids, Window(cursor, 0))
    changes = build_changes(groups, states, scopes, windows, {})
    return PullResponse(changes=changes, next_cursor=page[-1][0], has_more=len(rows) > limit)


__all__ = ["ScopeInfo", "pull_changes", "pull_scoped"]
