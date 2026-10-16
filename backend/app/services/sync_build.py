"""Entity states of a page turned into the changes a given role may receive (ADR 0006 §3, §4)."""

from __future__ import annotations

import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime
from typing import Any, cast

from app.schemas.sync import Change, EntityState
from app.services.sync_scopes import ScopeInfo
from app.services.sync_state import project_state

EntityKey = tuple[str, uuid.UUID]
GroupKey = tuple[uuid.UUID, str, uuid.UUID]
ENTITY_RANK = {"profile": 0, "medication": 1, "schedule": 2, "dose_event": 3}


@dataclass
class Group:
    """The journal rows of one entity in one page, collapsed."""

    first_seq: int
    last_seq: int
    privacy_changed_at: datetime | None = None  # newest ``privacy`` row, if any
    privacy_seq: int | None = None


@dataclass(frozen=True)
class Loaded:
    state: EntityState
    medication_privacy: str | None


def collapse(rows: list[Any]) -> dict[GroupKey, Group]:
    groups: dict[GroupKey, Group] = {}
    for seq, profile_id, entity, entity_id, op, created_at in rows:
        group = groups.setdefault((profile_id, entity, entity_id), Group(seq, seq))
        group.last_seq = seq
        if op == "privacy":
            group.privacy_changed_at = created_at
            group.privacy_seq = seq
    return groups


# --- building changes --------------------------------------------------------------------------


def _narrowing_delete(group: Group, key: GroupKey) -> Change:
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


@dataclass(frozen=True)
class Window:
    """What one scope's client may be told, by seq (ADR 0006 §4).

    ``sent`` is the cursor it sent. ``floor`` is ``max(granted_seq, backfill_until)``:
    everything at or below it is history the client never held, so a projected role
    gets no narrowing delete and no tombstone from it.
    """

    sent: int
    floor: int


def _may_emit_narrowing(
    group: Group,
    key: GroupKey,
    window: Window,
    created: Mapping[tuple[uuid.UUID, uuid.UUID], int],
) -> bool:
    """A delete for a medication that became hidden goes only to a client that may hold it.

    The narrowing must be newer than the grant and the backfill, and the medication must
    have appeared at or before the client's cursor: a medication created inside this very
    page (or later) was never delivered, so its id must not be revealed either.
    """
    if group.privacy_seq is None or group.privacy_seq <= window.floor:
        return False
    first = created.get((key[0], key[2]))
    return first is not None and first <= window.sent


def _change_for(
    key: GroupKey,
    group: Group,
    loaded: Loaded,
    scope: ScopeInfo,
    window: Window,
    created: Mapping[tuple[uuid.UUID, uuid.UUID], int],
) -> Change | None:
    profile_id, entity, entity_id = key
    projected = project_state(entity, loaded.state, scope.role, loaded.medication_privacy)
    if projected is None:
        if entity == "medication" and _may_emit_narrowing(group, key, window, created):
            return _narrowing_delete(group, key)
        return None
    # A tombstone of history from before the grant or inside the backfill would only tell
    # the relative that something once existed.
    if scope.projected and projected.op == "delete" and group.last_seq <= window.floor:
        return None
    return Change(
        seq=group.last_seq,
        scope=profile_id,
        entity=cast(Any, entity),
        id=entity_id,
        **projected.model_dump(),
    )


def narrowing_candidates(
    groups: Mapping[GroupKey, Group],
    states: Mapping[EntityKey, Loaded],
    scopes: Mapping[uuid.UUID, ScopeInfo],
    windows: Mapping[uuid.UUID, Window],
) -> set[tuple[uuid.UUID, uuid.UUID]]:
    """(scope, medication) pairs whose narrowing delete would be sent unless it was never seen."""
    out: set[tuple[uuid.UUID, uuid.UUID]] = set()
    for (profile_id, entity, entity_id), group in groups.items():
        loaded = states.get((entity, entity_id))
        if (
            entity == "medication"
            and loaded is not None
            and group.privacy_seq is not None
            and group.privacy_seq > windows[profile_id].floor
            and project_state(
                entity, loaded.state, scopes[profile_id].role, loaded.medication_privacy
            )
            is None
        ):
            out.add((profile_id, entity_id))
    return out


def build_changes(
    groups: Mapping[GroupKey, Group],
    states: Mapping[EntityKey, Loaded],
    scopes: Mapping[uuid.UUID, ScopeInfo],
    windows: Mapping[uuid.UUID, Window],
    created: Mapping[tuple[uuid.UUID, uuid.UUID], int],
) -> list[Change]:
    """Changes in page order: parents before children, then by first appearance."""
    ordered = sorted(groups.items(), key=lambda kv: (ENTITY_RANK[kv[0][1]], kv[1].first_seq))
    changes: list[Change] = []
    for key, group in ordered:
        loaded = states.get((key[1], key[2]))
        if loaded is None:  # pragma: no cover - journal rows always have an entity
            continue
        change = _change_for(key, group, loaded, scopes[key[0]], windows[key[0]], created)
        if change is not None:
            changes.append(change)
    return changes
