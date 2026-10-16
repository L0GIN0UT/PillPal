"""The scopes a pull lists: live ones through access, owned tombstones, owner last seen."""

from __future__ import annotations

import uuid
from collections.abc import Collection, Mapping
from dataclasses import dataclass
from datetime import datetime
from typing import cast

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Device, Profile, SyncChange
from app.domain.privacy import Role
from app.services.access import accessible_scopes

PROJECTED_ROLES: tuple[Role, ...] = ("editor", "viewer")


@dataclass(frozen=True)
class ScopeInfo:
    profile_id: uuid.UUID
    kind: str
    owner_id: uuid.UUID
    role: Role
    granted_seq: int  # journal head when the caller's grant was made (0 for the owner)
    archived: bool = False  # a read-only archive (D1): reminders and writes are off
    archive_purge_after: datetime | None = None  # set once the former owner is erased

    @property
    def projected(self) -> bool:
        return self.role in PROJECTED_ROLES


async def live_scopes(session: AsyncSession, user_id: uuid.UUID) -> dict[uuid.UUID, ScopeInfo]:
    scopes: dict[uuid.UUID, ScopeInfo] = {}
    for (
        pid,
        kind,
        owner_id,
        grant_role,
        granted_seq,
        archived_at,
        purge_after,
    ) in await session.execute(accessible_scopes(user_id)):
        role = "owner" if owner_id == user_id else cast(Role, grant_role)
        scopes[pid] = ScopeInfo(
            pid, kind, owner_id, role, granted_seq or 0, archived_at is not None, purge_after
        )
    return scopes


async def tombstoned_scopes(
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
        pid: ScopeInfo(pid, kind, user_id, "owner", 0)
        for pid, kind, last_seq in rows
        if cursors[pid] < last_seq
    }


async def owner_last_seen(
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
