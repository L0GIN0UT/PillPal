"""Sync pull (TZ §4.3, ADR 0006 §2): journal rows after a cursor, as current entity states.

Each change carries the entity's *current* state plus its conflict key, so a client
merges it with the same last-write-wins rule the server uses. Several journal rows
of one entity in a page collapse into one change.

``POST /v1/sync/pull`` reads one page of several scopes (profiles) under one
REPEATABLE READ snapshot, so the scope list, the journal rows and the entity
states agree. Relatives get the privacy projection (``app.domain.privacy``);
what it hides still *advances the cursor* (the cursor is the newest row read, not
the newest row returned), so a page made only of hidden rows cannot loop.
``GET /v1/sync/pull`` (one cursor over the caller's own scopes) is the Phase 2
form, kept until the app switches.
"""

from __future__ import annotations

import uuid
from collections.abc import Collection, Mapping
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, cast

from sqlalchemy import BigInteger, Uuid, column, func, select, values
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Device, DoseEvent, Medication, Profile, Schedule, SyncChange
from app.domain.privacy import Role, visible_last_seen
from app.schemas.entities import Change, EntityState, PullResponse
from app.schemas.sync import ScopedPullResponse, ScopeOut
from app.services.access import accessible_scopes
from app.services.devices import touch_device_throttled
from app.services.sync_state import entity_state, project_state

EntityKey = tuple[str, uuid.UUID]
GroupKey = tuple[uuid.UUID, str, uuid.UUID]
ENTITY_RANK = {"profile": 0, "medication": 1, "schedule": 2, "dose_event": 3}


@dataclass(frozen=True)
class ScopeInfo:
    profile_id: uuid.UUID
    kind: str
    owner_id: uuid.UUID
    role: Role
    granted_at: datetime | None  # when the caller's grant was created (None for the owner)


@dataclass
class _Group:
    """The journal rows of one entity in one page, collapsed."""

    first_seq: int
    last_seq: int
    privacy_changed_at: datetime | None = None  # newest ``privacy`` row, if any


@dataclass(frozen=True)
class _Loaded:
    state: EntityState
    medication_privacy: str | None


# --- scopes ------------------------------------------------------------------------------------


async def _live_scopes(session: AsyncSession, user_id: uuid.UUID) -> dict[uuid.UUID, ScopeInfo]:
    scopes: dict[uuid.UUID, ScopeInfo] = {}
    for pid, kind, owner_id, grant_role, granted_at in await session.execute(
        accessible_scopes(user_id)
    ):
        role = "owner" if owner_id == user_id else cast(Role, grant_role)
        scopes[pid] = ScopeInfo(pid, kind, owner_id, role, granted_at)
    return scopes


async def _tombstoned_scopes(
    session: AsyncSession, user_id: uuid.UUID, cursors: Mapping[uuid.UUID, int]
) -> dict[uuid.UUID, ScopeInfo]:
    """Owned, deleted profiles whose deletion the client has not pulled yet.

    Listed only while the client's cursor is below the tombstone's seq, so deleted
    managed profiles do not pile up in ``scopes`` for ever.
    """
    if not cursors:
        return {}
    rows = await session.execute(
        select(Profile.id, Profile.kind, func.max(SyncChange.seq))
        .join(SyncChange, SyncChange.profile_id == Profile.id)
        .where(
            Profile.owner_user_id == user_id,
            Profile.deleted_at.is_not(None),
            Profile.id.in_(list(cursors)),
        )
        .group_by(Profile.id, Profile.kind)
    )
    return {
        pid: ScopeInfo(pid, kind, user_id, "owner", None)
        for pid, kind, last_seq in rows
        if cursors[pid] < last_seq
    }


async def _owner_last_seen(
    session: AsyncSession, scopes: Collection[ScopeInfo]
) -> dict[uuid.UUID, datetime]:
    owners = {s.owner_id for s in scopes if s.role != "owner" and s.kind == "self"}
    if not owners:
        return {}
    rows = await session.execute(
        select(Device.user_id, func.max(Device.last_seen_at))
        .where(Device.user_id.in_(owners))
        .group_by(Device.user_id)
    )
    return dict(rows.all())


# --- journal rows ------------------------------------------------------------------------------


async def _read_rows(
    session: AsyncSession, cursors: Mapping[uuid.UUID, int], limit: int
) -> list[Any]:
    """Up to ``limit + 1`` rows after each scope's own cursor, in seq order (one probe row)."""
    if not cursors:
        return []
    wanted = values(
        column("profile_id", Uuid), column("after_seq", BigInteger), name="wanted"
    ).data(list(cursors.items()))
    stmt = (
        select(
            SyncChange.seq,
            SyncChange.profile_id,
            SyncChange.entity,
            SyncChange.entity_id,
            SyncChange.op,
            SyncChange.created_at,
        )
        .join(wanted, wanted.c.profile_id == SyncChange.profile_id)
        .where(SyncChange.seq > wanted.c.after_seq)
        .order_by(SyncChange.seq)
        .limit(limit + 1)
    )
    return list((await session.execute(stmt)).all())


def _collapse(rows: list[Any]) -> dict[GroupKey, _Group]:
    groups: dict[GroupKey, _Group] = {}
    for seq, profile_id, entity, entity_id, op, created_at in rows:
        group = groups.setdefault((profile_id, entity, entity_id), _Group(seq, seq))
        group.last_seq = seq
        if op == "privacy":
            group.privacy_changed_at = created_at
    return groups


# --- entity states -----------------------------------------------------------------------------


async def _load_states(
    session: AsyncSession, groups: Collection[GroupKey], scope_ids: Collection[uuid.UUID]
) -> dict[EntityKey, _Loaded]:
    """Current state of every entity in ``groups``; only rows inside ``scope_ids`` load."""
    by_entity: dict[str, list[uuid.UUID]] = {}
    for _, entity, entity_id in groups:
        by_entity.setdefault(entity, []).append(entity_id)
    scopes = list(scope_ids)
    out: dict[EntityKey, _Loaded] = {}
    if ids := by_entity.get("profile"):
        stmt = select(Profile).where(Profile.id.in_(ids), Profile.id.in_(scopes))
        for profile in await session.scalars(stmt):
            out[("profile", profile.id)] = _Loaded(entity_state("profile", profile), None)
    if ids := by_entity.get("medication"):
        med_stmt = select(Medication).where(
            Medication.id.in_(ids), Medication.profile_id.in_(scopes)
        )
        for med in await session.scalars(med_stmt):
            out[("medication", med.id)] = _Loaded(entity_state("medication", med), med.privacy)
    for schedule, privacy in await _children(session, Schedule, by_entity, scopes):
        out[("schedule", schedule.id)] = _Loaded(entity_state("schedule", schedule), privacy)
    for event, privacy in await _children(session, DoseEvent, by_entity, scopes):
        out[("dose_event", event.id)] = _Loaded(entity_state("dose_event", event), privacy)
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


# --- building changes --------------------------------------------------------------------------


def _narrowing_delete(group: _Group, key: GroupKey) -> Change:
    """Tell a relative to drop a medication that just became hidden from them.

    The time is the journal row's, not the medication's: a hidden medication's own
    edit times must not leak through this tombstone.
    """
    at = group.privacy_changed_at
    profile_id, _, entity_id = key
    return Change(
        seq=group.last_seq,
        scope=profile_id,
        entity="medication",
        id=entity_id,
        op="delete",
        data=None,
        client_updated_at=at,
        updated_by_device=None,
        deleted_at=at,
    )


def _may_emit_narrowing(group: _Group, scope: ScopeInfo, sent_cursor: int) -> bool:
    """A delete for a hidden medication is sent only to a client that could hold it.

    Never on a backfill from cursor 0, and never for a narrowing that happened before
    the caller's grant existed (any cursor): such a delete would reveal the id, and the
    number, of medications the client never saw.
    """
    at = group.privacy_changed_at
    if at is None or sent_cursor == 0:
        return False
    return scope.granted_at is None or at >= scope.granted_at


def _change_for(
    key: GroupKey, group: _Group, loaded: _Loaded, scope: ScopeInfo, sent_cursor: int
) -> Change | None:
    profile_id, entity, entity_id = key
    projected = project_state(entity, loaded.state, scope.role, loaded.medication_privacy)
    if projected is None:
        if entity == "medication" and _may_emit_narrowing(group, scope, sent_cursor):
            return _narrowing_delete(group, key)
        return None
    return Change(
        seq=group.last_seq,
        scope=profile_id,
        entity=cast(Any, entity),
        id=entity_id,
        **projected.model_dump(),
    )


def _build_changes(
    groups: Mapping[GroupKey, _Group],
    states: Mapping[EntityKey, _Loaded],
    scopes: Mapping[uuid.UUID, ScopeInfo],
    sent: Mapping[uuid.UUID, int],
) -> list[Change]:
    """Changes in page order: parents before children, then by first appearance."""
    ordered = sorted(groups.items(), key=lambda kv: (ENTITY_RANK[kv[0][1]], kv[1].first_seq))
    changes: list[Change] = []
    for key, group in ordered:
        loaded = states.get((key[1], key[2]))
        if loaded is None:  # pragma: no cover - journal rows always have an entity
            continue
        change = _change_for(key, group, loaded, scopes[key[0]], sent[key[0]])
        if change is not None:
            changes.append(change)
    return changes


# --- POST /v1/sync/pull ------------------------------------------------------------------------


def _scope_out(
    scope: ScopeInfo,
    cursors: Mapping[uuid.UUID, int],
    last_seen: Mapping[uuid.UUID, datetime],
) -> ScopeOut:
    return ScopeOut(
        profile_id=scope.profile_id,
        role=scope.role,
        kind=cast(Any, scope.kind),
        archived=False,
        archive_purge_after=None,
        owner_last_seen_at=visible_last_seen(scope.role, scope.kind, last_seen.get(scope.owner_id)),
        cursor=cursors.get(scope.profile_id),
    )


async def pull_scoped(
    session: AsyncSession,
    user_id: uuid.UUID,
    device_id: str,
    cursors: Mapping[uuid.UUID, int],
    limit: int,
    *,
    touch_interval: timedelta,
) -> ScopedPullResponse:
    """One page for the requested scopes under a REPEATABLE READ snapshot."""
    await touch_device_throttled(session, user_id, device_id, touch_interval)
    await session.commit()  # the isolation level can only be set on a fresh transaction
    await session.connection(execution_options={"isolation_level": "REPEATABLE READ"})
    try:
        return await _pull_page(session, user_id, cursors, limit)
    finally:
        await session.rollback()  # read-only: ends the snapshot


async def _pull_page(
    session: AsyncSession, user_id: uuid.UUID, cursors: Mapping[uuid.UUID, int], limit: int
) -> ScopedPullResponse:
    scopes = await _live_scopes(session, user_id)
    unseen = {pid: cursor for pid, cursor in cursors.items() if pid not in scopes}
    scopes |= await _tombstoned_scopes(session, user_id, unseen)
    requested = {pid: cursor for pid, cursor in cursors.items() if pid in scopes}
    rows = await _read_rows(session, requested, limit)
    page = rows[:limit]
    groups = _collapse(page)
    states = await _load_states(session, groups, requested)
    changes = _build_changes(groups, states, scopes, requested)
    new_cursors = dict(requested)
    for seq, profile_id, *_ in page:
        new_cursors[profile_id] = max(new_cursors[profile_id], seq)
    last_seen = await _owner_last_seen(session, list(scopes.values()))
    return ScopedPullResponse(
        scopes=[_scope_out(s, new_cursors, last_seen) for s in scopes.values()],
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
    groups = _collapse(list(page))
    scope_ids = {key[0] for key in groups}
    scopes = {pid: ScopeInfo(pid, "", user_id, "owner", None) for pid in scope_ids}
    states = await _load_states(session, groups, scope_ids)
    changes = _build_changes(groups, states, scopes, dict.fromkeys(scope_ids, cursor))
    return PullResponse(changes=changes, next_cursor=page[-1][0], has_more=len(rows) > limit)


__all__ = ["ScopeInfo", "pull_changes", "pull_scoped"]
