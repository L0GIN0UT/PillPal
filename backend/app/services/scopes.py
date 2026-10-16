"""Journal scopes: whose lock a write needs, resolved through access (ADR 0006 §1).

A write journals into the scope (profile) it touches and holds the lock of that
scope's *owner* (:mod:`app.services.changes`). Owners are found only through
profiles the caller can access: an id that does not resolve is not locked (no
lock on a stranger's owner, no timing oracle) and the write is rejected as if
the id did not exist.

Between resolving and locking, a profile may change owner (the D1 transfer of a
managed profile, milestone 3.3b). After the locks are held the owners are read
again; if the answer changed, the locks are released and the whole step is
repeated, at most :data:`MAX_LOCK_ATTEMPTS` times (then ``503 retry_later``).
Nothing but reads has happened before this point, so a retry is just a re-run.
"""

from __future__ import annotations

import contextlib
import uuid
from collections.abc import Awaitable, Callable, Iterable, Sequence
from dataclasses import dataclass
from typing import Any

from sqlalchemy import Select, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import DoseEvent, Medication, Profile, Schedule
from app.errors import AppError, not_found
from app.schemas.entities import Mutation
from app.services.access import ALL_ROLES, Role, accessible_profiles, has_full_access
from app.services.changes import lock_journal

MAX_LOCK_ATTEMPTS = 3


@dataclass(frozen=True)
class ScopeLock:
    """The scope a REST write holds the lock of, and the caller's role in it."""

    profile_id: uuid.UUID
    owner_id: uuid.UUID
    role: Role


def retry_later() -> AppError:
    return AppError(503, "retry_later", "Temporarily unavailable, retry")


async def lock_stable[T](
    session: AsyncSession,
    resolve: Callable[[], Awaitable[T]],
    owners_of: Callable[[T], Iterable[uuid.UUID]],
) -> T:
    """Lock the owners ``resolve`` finds, and make sure they are still the owners.

    ``resolve`` is called again with the locks held; a different answer means an
    owner changed in between, so the locks are released (the transaction ends:
    only reads happened) and everything is retried.
    """
    for _ in range(MAX_LOCK_ATTEMPTS):
        found = await resolve()
        await lock_journal(session, list(owners_of(found)))
        if await resolve() == found:
            return found
        await session.commit()
    raise retry_later()


# --- REST: one scope per request ------------------------------------------------------


async def _find_scope(
    session: AsyncSession, user_id: uuid.UUID, stmt: Select[uuid.UUID, uuid.UUID]
) -> ScopeLock | None:
    row = (await session.execute(stmt.where(has_full_access(user_id)))).one_or_none()
    if row is None:
        return None
    profile_id, owner_id = row
    return ScopeLock(profile_id, owner_id, "owner" if owner_id == user_id else "guardian")


async def _lock_scope(
    session: AsyncSession, user_id: uuid.UUID, stmt: Select[uuid.UUID, uuid.UUID]
) -> ScopeLock:
    async def resolve() -> ScopeLock | None:
        return await _find_scope(session, user_id, stmt)

    scope = await lock_stable(
        session, resolve, lambda found: [] if found is None else [found.owner_id]
    )
    if scope is None:
        raise not_found()
    return scope


async def lock_for_profile(
    session: AsyncSession, user_id: uuid.UUID, profile_id: uuid.UUID
) -> ScopeLock:
    """Lock the scope of a profile the caller owns or guards; anything else is 404."""
    stmt = select(Profile.id, Profile.owner_user_id).where(Profile.id == profile_id)
    return await _lock_scope(session, user_id, stmt)


async def lock_for_medication(
    session: AsyncSession, user_id: uuid.UUID, medication_id: uuid.UUID
) -> ScopeLock:
    stmt = (
        select(Profile.id, Profile.owner_user_id)
        .join(Medication, Medication.profile_id == Profile.id)
        .where(Medication.id == medication_id)
    )
    return await _lock_scope(session, user_id, stmt)


async def lock_for_schedule(
    session: AsyncSession, user_id: uuid.UUID, schedule_id: uuid.UUID
) -> ScopeLock:
    stmt = (
        select(Profile.id, Profile.owner_user_id)
        .join(Medication, Medication.profile_id == Profile.id)
        .join(Schedule, Schedule.medication_id == Medication.id)
        .where(Schedule.id == schedule_id)
    )
    return await _lock_scope(session, user_id, stmt)


# --- sync push: every owner a batch touches --------------------------------------------


@dataclass
class _Referenced:
    profiles: set[uuid.UUID]
    medications: set[uuid.UUID]
    schedules: set[uuid.UUID]
    events: set[uuid.UUID]


def _add(ids: set[uuid.UUID], value: object) -> None:
    with contextlib.suppress(ValueError):  # not an id: validation rejects the mutation later
        ids.add(uuid.UUID(str(value)))


def _referenced_ids(mutations: Sequence[Mutation]) -> _Referenced:
    """Every id of a batch that could name a profile, medication, schedule or event.

    Payload ids are untrusted hints: they only decide which scopes get *looked up*,
    and only accessible ones are ever locked.
    """
    refs = _Referenced(set(), set(), set(), set())
    for m in mutations:
        data = m.data or {}
        if m.entity == "profile":
            refs.profiles.add(m.id)
        elif m.entity == "medication":
            refs.medications.add(m.id)
            _add(refs.profiles, data.get("profile_id"))
        elif m.entity == "schedule":
            refs.schedules.add(m.id)
            _add(refs.medications, data.get("medication_id"))
        else:
            refs.events.add(m.id)
            _add(refs.medications, data.get("medication_id"))
    return refs


async def resolve_batch_owners(
    session: AsyncSession, user_id: uuid.UUID, mutations: Sequence[Mutation]
) -> frozenset[uuid.UUID]:
    """Owners of the accessible scopes a batch touches, plus the caller.

    The caller's own lock is always included: new profiles and the device record are
    theirs. Ids that do not resolve through an accessible profile contribute nothing.
    """
    refs = _referenced_ids(mutations)
    accessible = accessible_profiles(user_id, ALL_ROLES).subquery()
    visible = Profile.id.in_(select(accessible.c.id))
    base = select(Profile.owner_user_id).where(visible).distinct()
    queries: list[Select[Any]] = []
    if refs.profiles:
        queries.append(base.where(Profile.id.in_(refs.profiles)))
    if refs.medications:
        queries.append(
            base.join(Medication, Medication.profile_id == Profile.id).where(
                Medication.id.in_(refs.medications)
            )
        )
    if refs.schedules:
        queries.append(
            base.join(Medication, Medication.profile_id == Profile.id)
            .join(Schedule, Schedule.medication_id == Medication.id)
            .where(Schedule.id.in_(refs.schedules))
        )
    if refs.events:
        queries.append(
            base.join(DoseEvent, DoseEvent.profile_id == Profile.id).where(
                DoseEvent.id.in_(refs.events)
            )
        )
    owners = {user_id}
    for stmt in queries:
        owners.update(await session.scalars(stmt))
    return frozenset(owners)


async def lock_batch_owners(
    session: AsyncSession, user_id: uuid.UUID, mutations: Sequence[Mutation]
) -> frozenset[uuid.UUID]:
    """Lock every owner a push batch touches; see :func:`lock_stable`."""

    async def resolve() -> frozenset[uuid.UUID]:
        return await resolve_batch_owners(session, user_id, mutations)

    return await lock_stable(session, resolve, lambda owners: owners)
