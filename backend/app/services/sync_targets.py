"""The target of a pushed mutation, loaded *before* anyone decides whether it may be touched.

Sync push loads the entity by id without an access filter, works out the caller's
role on its profile, and only then lets ``app.domain.write_access`` decide
(ADR 0006 §6). That order is what keeps an upsert carrying the id of an entity the
caller cannot see from ever reaching the create branch (no ``integrity_error`` or
``already_exists`` oracle).

A role only counts in a scope whose owner lock the transaction holds: access that
appeared after the batch resolved its owners (a grant accepted in between) is
treated as absent, so every journal write stays under its owner's lock.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any, Literal

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import DoseEvent, Medication, Profile, Schedule
from app.domain.privacy import Role
from app.services.access import role_on_profile
from app.services.changes import held_owner_locks

Lock = Literal["update", "share"] | None


@dataclass(frozen=True)
class Target:
    """What a mutation points at.

    ``row`` is the entity if it exists (any scope, tombstones included). ``profile`` is the
    scope the mutation belongs to; ``parent`` is the existing parent of an entity that is
    being created. ``role`` is the caller's role there (``None``: no access) and
    ``medication_privacy`` the privacy of the medication involved.
    """

    row: Any
    profile: Profile | None
    role: Role | None
    medication_privacy: str | None = None
    parent: Medication | None = None


async def fetch[M: (Profile, Medication, Schedule, DoseEvent)](
    session: AsyncSession, model: type[M], row_id: uuid.UUID, lock: Lock = None
) -> M | None:
    """Load a row by id with no access filter. Only this module's callers decide access."""
    stmt = select(model).where(model.id == row_id)
    if lock is not None:
        # populate_existing: bulk cascades bypass the identity map, so a locked
        # read must refresh any instance this session already holds.
        stmt = stmt.with_for_update(read=lock == "share").execution_options(populate_existing=True)
    return await session.scalar(stmt)


class TargetResolver:
    def __init__(self, session: AsyncSession, user_id: uuid.UUID) -> None:
        self.session = session
        self.user_id = user_id
        self._roles: dict[uuid.UUID, Role | None] = {}

    async def _role(self, profile: Profile | None) -> Role | None:
        if profile is None or profile.owner_user_id not in held_owner_locks(self.session):
            return None
        if profile.id not in self._roles:
            self._roles[profile.id] = await role_on_profile(self.session, self.user_id, profile)
        return self._roles[profile.id]

    async def _lock[M: (Profile, Medication, Schedule)](
        self, model: type[M], row: M | None, role: Role | None, mode: Lock
    ) -> M | None:
        """Take a row lock on a row the caller may use; never on a foreign row.

        Locking first and deciding afterwards would let a stranger wait on (and so
        detect) rows of other accounts. ``update`` is for rows about to change;
        ``share`` is for the parent of a child being created, so a concurrent delete
        of the parent waits for the insert instead of racing past it.
        """
        if row is None or role is None:
            return row
        return await fetch(self.session, model, row.id, mode)

    async def profile(self, profile_id: uuid.UUID) -> Target:
        row = await fetch(self.session, Profile, profile_id)
        if row is None:
            # A new managed profile is created by the caller, in their own scope.
            return Target(None, None, "owner")
        role = await self._role(row)
        row = await self._lock(Profile, row, role, "update")
        return Target(row, row, role)

    async def medication(
        self, medication_id: uuid.UUID, payload_profile_id: uuid.UUID | None
    ) -> Target:
        row = await fetch(self.session, Medication, medication_id)
        if row is not None:
            profile = await fetch(self.session, Profile, row.profile_id)
            role = await self._role(profile)
            row = await self._lock(Medication, row, role, "update")
            return Target(row, profile, role, row.privacy if row else None)
        profile = (
            await fetch(self.session, Profile, payload_profile_id)
            if payload_profile_id is not None
            else None
        )
        role = await self._role(profile)
        return Target(None, await self._lock(Profile, profile, role, "share"), role)

    async def schedule(
        self, schedule_id: uuid.UUID, payload_medication_id: uuid.UUID | None
    ) -> Target:
        row = await fetch(self.session, Schedule, schedule_id)
        medication_id = row.medication_id if row is not None else payload_medication_id
        target = await self._under_medication(row, medication_id)
        if row is None:
            parent = await self._lock(Medication, target.parent, target.role, "share")
            return Target(None, target.profile, target.role, target.medication_privacy, parent)
        locked = await self._lock(Schedule, row, target.role, "update")
        return Target(locked, target.profile, target.role, target.medication_privacy, target.parent)

    async def dose_event(self, event_id: uuid.UUID, payload_medication_id: uuid.UUID) -> Target:
        row = await fetch(self.session, DoseEvent, event_id)
        medication_id = row.medication_id if row is not None else payload_medication_id
        return await self._under_medication(row, medication_id)

    async def _under_medication(self, row: Any | None, medication_id: uuid.UUID | None) -> Target:
        medication = (
            await fetch(self.session, Medication, medication_id)
            if medication_id is not None
            else None
        )
        profile = await fetch(self.session, Profile, medication.profile_id) if medication else None
        privacy = medication.privacy if medication is not None else None
        return Target(row, profile, await self._role(profile), privacy, medication)
