"""Access-scoped reads of profiles, medications and schedules (REST and the sync writers).

Every read is filtered by the caller's *full access* in the SQL query (owner, or
guardian of a managed profile; join up to ``profiles``), so a foreign id, or one
that only an editor or viewer may see, behaves exactly like a missing one.
Relatives with a projected role use sync only (ADR 0006).
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from typing import Any, Literal

from sqlalchemy import Select, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Medication, Profile, Schedule
from app.services.access import has_full_access

# Row locks for loaders: "update" before modifying a row, "share" on a parent
# while creating a child, so a concurrent parent delete cannot slip between
# the parent check and the child insert.
Lock = Literal["update", "share"] | None


def _finish[S: Select[Any]](stmt: S, entity: Any, include_deleted: bool, lock: Lock) -> S:
    if not include_deleted:
        stmt = stmt.where(entity.deleted_at.is_(None))
    if lock is not None:
        # populate_existing: bulk cascades bypass the identity map, so a locked
        # read must refresh any instance this session already holds.
        stmt = stmt.with_for_update(of=entity, read=lock == "share").execution_options(
            populate_existing=True
        )
    return stmt


async def load_profile(
    session: AsyncSession,
    user_id: uuid.UUID,
    profile_id: uuid.UUID,
    *,
    include_deleted: bool = False,
    lock: Lock = None,
    owner_only: bool = False,
) -> Profile | None:
    """``owner_only``: invites and grants are the owner's alone (ADR 0005 §2)."""
    access = Profile.owner_user_id == user_id if owner_only else has_full_access(user_id)
    stmt = select(Profile).where(Profile.id == profile_id, access)
    return await session.scalar(_finish(stmt, Profile, include_deleted, lock))


async def load_medication(
    session: AsyncSession,
    user_id: uuid.UUID,
    medication_id: uuid.UUID,
    *,
    include_deleted: bool = False,
    lock: Lock = None,
) -> Medication | None:
    stmt = (
        select(Medication)
        .join(Profile, Profile.id == Medication.profile_id)
        .where(Medication.id == medication_id, has_full_access(user_id))
    )
    return await session.scalar(_finish(stmt, Medication, include_deleted, lock))


async def load_schedule(
    session: AsyncSession,
    user_id: uuid.UUID,
    schedule_id: uuid.UUID,
    *,
    include_deleted: bool = False,
    lock: Lock = None,
) -> Schedule | None:
    stmt = (
        select(Schedule)
        .join(Medication, Medication.id == Schedule.medication_id)
        .join(Profile, Profile.id == Medication.profile_id)
        .where(Schedule.id == schedule_id, has_full_access(user_id))
    )
    return await session.scalar(_finish(stmt, Schedule, include_deleted, lock))


# --- lists --------------------------------------------------------------------


async def list_profiles(session: AsyncSession, user_id: uuid.UUID) -> Sequence[Profile]:
    rows = await session.scalars(
        select(Profile)
        .where(has_full_access(user_id), Profile.deleted_at.is_(None))
        .order_by(Profile.created_at, Profile.id)
    )
    return rows.all()


async def list_medications(
    session: AsyncSession, user_id: uuid.UUID, profile_id: uuid.UUID
) -> Sequence[Medication]:
    rows = await session.scalars(
        select(Medication)
        .join(Profile, Profile.id == Medication.profile_id)
        .where(
            Medication.profile_id == profile_id,
            has_full_access(user_id),
            Profile.deleted_at.is_(None),
            Medication.deleted_at.is_(None),
        )
        .order_by(Medication.created_at, Medication.id)
    )
    return rows.all()


async def list_schedules(
    session: AsyncSession, user_id: uuid.UUID, medication_id: uuid.UUID
) -> Sequence[Schedule]:
    rows = await session.scalars(
        select(Schedule)
        .join(Medication, Medication.id == Schedule.medication_id)
        .join(Profile, Profile.id == Medication.profile_id)
        .where(
            Schedule.medication_id == medication_id,
            has_full_access(user_id),
            Medication.deleted_at.is_(None),
            Schedule.deleted_at.is_(None),
        )
        .order_by(Schedule.created_at, Schedule.id)
    )
    return rows.all()
