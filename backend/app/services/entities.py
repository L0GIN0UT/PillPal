"""Profiles, medications and schedules: owner-scoped reads and writes.

Every read is filtered by the owning user *in the SQL query* (join up to
``profiles.owner_user_id``), so a foreign id behaves exactly like a missing
one. Every write bumps ``version``, stamps the last-write-wins key and is
journaled in ``sync_changes`` within the caller's transaction; callers take
the journal lock first (``app.services.changes.lock_journal``) and commit.

Deletes are tombstones without content: ids, version and the conflict key
stay, names/notes/rules are erased. Deleting a parent tombstones its children.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Literal

from sqlalchemy import DateTime, Select, Text, case, literal, null, select, tuple_, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import (
    MEDICATION_CONTENT,
    PROFILE_CONTENT,
    SCHEDULE_CONTENT,
    Medication,
    Profile,
    Schedule,
)
from app.errors import AppError
from app.services.changes import record_change, record_changes

ONE_MICROSECOND = timedelta(microseconds=1)
UNIQUE_VIOLATION = "23505"
# Row locks for loaders: "update" before modifying a row, "share" on a parent
# while creating a child, so a concurrent parent delete cannot slip between
# the parent check and the child insert.
Lock = Literal["update", "share"] | None


def utcnow() -> datetime:
    return datetime.now(UTC)


@dataclass(frozen=True)
class WriteContext:
    """Who writes and with which last-write-wins key."""

    user_id: uuid.UUID
    device: str
    client_updated_at: datetime

    @classmethod
    def server(cls, user_id: uuid.UUID, device: str | None) -> WriteContext:
        return cls(user_id=user_id, device=device or "", client_updated_at=utcnow())

    def for_row(self, current: datetime) -> WriteContext:
        """Direct (REST) writes always win: keep the LWW key monotonic per row."""
        if self.client_updated_at > current:
            return self
        return WriteContext(self.user_id, self.device, current + ONE_MICROSECOND)


def already_exists() -> AppError:
    return AppError(409, "already_exists", "An entity with this id already exists")


def _is_primary_key_violation(exc: IntegrityError) -> bool:
    orig = exc.orig
    constraint = getattr(getattr(orig, "__cause__", None), "constraint_name", None) or ""
    return getattr(orig, "sqlstate", None) == UNIQUE_VIOLATION and constraint.startswith("pk_")


async def insert_new(session: AsyncSession, obj: object) -> None:
    try:
        async with session.begin_nested():
            session.add(obj)
    except IntegrityError as exc:
        # Ids are client-generated; a collision (with any user's row) is a
        # conflict. Any other violation is a bug and must not be disguised.
        if _is_primary_key_violation(exc):
            raise already_exists() from None
        raise


# --- owner-scoped loaders -----------------------------------------------------


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
) -> Profile | None:
    stmt = select(Profile).where(Profile.id == profile_id, Profile.owner_user_id == user_id)
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
        .where(Medication.id == medication_id, Profile.owner_user_id == user_id)
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
        .where(Schedule.id == schedule_id, Profile.owner_user_id == user_id)
    )
    return await session.scalar(_finish(stmt, Schedule, include_deleted, lock))


# --- lists --------------------------------------------------------------------


async def list_profiles(session: AsyncSession, user_id: uuid.UUID) -> Sequence[Profile]:
    rows = await session.scalars(
        select(Profile)
        .where(Profile.owner_user_id == user_id, Profile.deleted_at.is_(None))
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
            Profile.owner_user_id == user_id,
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
            Profile.owner_user_id == user_id,
            Medication.deleted_at.is_(None),
            Schedule.deleted_at.is_(None),
        )
        .order_by(Schedule.created_at, Schedule.id)
    )
    return rows.all()


# --- writes: common -----------------------------------------------------------


def _stamp(row: Profile | Medication | Schedule, ctx: WriteContext) -> None:
    row.version += 1
    row.client_updated_at = ctx.client_updated_at
    row.updated_by_device = ctx.device
    row.updated_at = utcnow()


def _tombstone_row(
    row: Profile | Medication | Schedule, ctx: WriteContext, content: tuple[str, ...]
) -> None:
    """Delete ``row``: erase its content; the conflict key never moves backwards."""
    if (ctx.client_updated_at, ctx.device) > (row.client_updated_at, row.updated_by_device):
        row.client_updated_at = ctx.client_updated_at
        row.updated_by_device = ctx.device
    row.version += 1
    row.deleted_at = row.updated_at = utcnow()
    for column in content:
        setattr(row, column, None)


def _tombstone_values(ctx: WriteContext, entity: Any, content: tuple[str, ...]) -> dict[str, Any]:
    """SET clause of a cascaded delete: GREATEST(existing key, ctx key), content erased."""
    ts = literal(ctx.client_updated_at, DateTime(timezone=True))
    device = literal(ctx.device, Text())
    newer = tuple_(entity.client_updated_at, entity.updated_by_device) < tuple_(ts, device)
    now = utcnow()
    return {
        "deleted_at": now,
        "updated_at": now,
        "version": entity.version + 1,
        "client_updated_at": case((newer, ts), else_=entity.client_updated_at),
        "updated_by_device": case((newer, device), else_=entity.updated_by_device),
        **{column: null() for column in content},
    }


async def _tombstone_schedules_of(
    session: AsyncSession, ctx: WriteContext, medication_ids: Sequence[uuid.UUID]
) -> None:
    if not medication_ids:
        return
    ids = (
        await session.scalars(
            update(Schedule)
            .where(Schedule.medication_id.in_(medication_ids), Schedule.deleted_at.is_(None))
            .values(**_tombstone_values(ctx, Schedule, SCHEDULE_CONTENT))
            .returning(Schedule.id)
            .execution_options(synchronize_session=False)
        )
    ).all()
    await record_changes(session, ctx.user_id, "schedule", list(ids), "delete")


# --- profiles -----------------------------------------------------------------


async def create_profile(
    session: AsyncSession,
    ctx: WriteContext,
    *,
    profile_id: uuid.UUID,
    display_name: str,
    timezone: str,
    settings: dict[str, Any] | None = None,
) -> Profile:
    row = Profile(
        id=profile_id,
        owner_user_id=ctx.user_id,
        kind="managed",
        display_name=display_name,
        timezone=timezone,
        version=1,
        client_updated_at=ctx.client_updated_at,
        updated_by_device=ctx.device,
        **(settings or {}),
    )
    await insert_new(session, row)
    await record_change(session, ctx.user_id, "profile", row.id, "upsert")
    return row


async def update_profile(
    session: AsyncSession, ctx: WriteContext, row: Profile, changes: dict[str, Any]
) -> Profile:
    for key, value in changes.items():
        setattr(row, key, value)
    _stamp(row, ctx)
    await record_change(session, ctx.user_id, "profile", row.id, "upsert")
    return row


async def delete_profile(session: AsyncSession, ctx: WriteContext, row: Profile) -> None:
    if row.kind == "self":
        raise AppError(409, "self_profile_protected", "The self profile cannot be deleted")
    _tombstone_row(row, ctx, PROFILE_CONTENT)
    await record_change(session, ctx.user_id, "profile", row.id, "delete")
    med_ids = (
        await session.scalars(
            update(Medication)
            .where(Medication.profile_id == row.id, Medication.deleted_at.is_(None))
            .values(**_tombstone_values(ctx, Medication, MEDICATION_CONTENT))
            .returning(Medication.id)
            .execution_options(synchronize_session=False)
        )
    ).all()
    await record_changes(session, ctx.user_id, "medication", list(med_ids), "delete")
    all_med_ids = (
        await session.scalars(select(Medication.id).where(Medication.profile_id == row.id))
    ).all()
    await _tombstone_schedules_of(session, ctx, all_med_ids)


# --- medications --------------------------------------------------------------


async def create_medication(
    session: AsyncSession,
    ctx: WriteContext,
    *,
    medication_id: uuid.UUID,
    profile_id: uuid.UUID,
    fields: dict[str, Any],
) -> Medication:
    row = Medication(
        id=medication_id,
        profile_id=profile_id,
        version=1,
        client_updated_at=ctx.client_updated_at,
        updated_by_device=ctx.device,
        **fields,
    )
    await insert_new(session, row)
    await record_change(session, ctx.user_id, "medication", row.id, "upsert")
    return row


async def update_medication(
    session: AsyncSession, ctx: WriteContext, row: Medication, fields: dict[str, Any]
) -> Medication:
    for key, value in fields.items():
        setattr(row, key, value)
    _stamp(row, ctx)
    await record_change(session, ctx.user_id, "medication", row.id, "upsert")
    return row


async def delete_medication(session: AsyncSession, ctx: WriteContext, row: Medication) -> None:
    _tombstone_row(row, ctx, MEDICATION_CONTENT)
    await record_change(session, ctx.user_id, "medication", row.id, "delete")
    await _tombstone_schedules_of(session, ctx, [row.id])


# --- schedules ----------------------------------------------------------------


async def create_schedule(
    session: AsyncSession,
    ctx: WriteContext,
    *,
    schedule_id: uuid.UUID,
    medication_id: uuid.UUID,
    rule: dict[str, Any],
) -> Schedule:
    row = Schedule(
        id=schedule_id,
        medication_id=medication_id,
        rule=rule,
        version=1,
        client_updated_at=ctx.client_updated_at,
        updated_by_device=ctx.device,
    )
    await insert_new(session, row)
    await record_change(session, ctx.user_id, "schedule", row.id, "upsert")
    return row


async def update_schedule(
    session: AsyncSession, ctx: WriteContext, row: Schedule, rule: dict[str, Any]
) -> Schedule:
    row.rule = rule
    _stamp(row, ctx)
    await record_change(session, ctx.user_id, "schedule", row.id, "upsert")
    return row


async def delete_schedule(session: AsyncSession, ctx: WriteContext, row: Schedule) -> None:
    _tombstone_row(row, ctx, SCHEDULE_CONTENT)
    await record_change(session, ctx.user_id, "schedule", row.id, "delete")
