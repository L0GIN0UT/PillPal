"""Profiles, medications, schedules and dose events: owner-scoped reads and writes.

Every read is filtered by the owning user *in the SQL query* (join up to
``profiles.owner_user_id``), so a foreign id behaves exactly like a missing
one. Every write bumps ``version``, stamps the last-write-wins key and is
journaled in ``sync_changes`` within the caller's transaction. Callers commit.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import Select, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import DoseEvent, Medication, Profile, Schedule
from app.errors import AppError
from app.schemas.entities import DoseEventData, occurrence_schedule_id
from app.services.changes import record_change, record_changes

ONE_MICROSECOND = timedelta(microseconds=1)


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


async def _insert(session: AsyncSession, obj: object) -> None:
    try:
        async with session.begin_nested():
            session.add(obj)
    except IntegrityError:
        # Ids are client-generated; a collision (with any user's row) is a conflict.
        raise already_exists() from None


# --- owner-scoped loaders -----------------------------------------------------


def _finish[S: Select[Any]](stmt: S, entity: Any, include_deleted: bool, lock: bool) -> S:
    if not include_deleted:
        stmt = stmt.where(entity.deleted_at.is_(None))
    if lock:
        stmt = stmt.with_for_update(of=entity)
    return stmt


async def load_profile(
    session: AsyncSession,
    user_id: uuid.UUID,
    profile_id: uuid.UUID,
    *,
    include_deleted: bool = False,
    lock: bool = False,
) -> Profile | None:
    stmt = select(Profile).where(Profile.id == profile_id, Profile.owner_user_id == user_id)
    return await session.scalar(_finish(stmt, Profile, include_deleted, lock))


async def load_medication(
    session: AsyncSession,
    user_id: uuid.UUID,
    medication_id: uuid.UUID,
    *,
    include_deleted: bool = False,
    lock: bool = False,
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
    lock: bool = False,
) -> Schedule | None:
    stmt = (
        select(Schedule)
        .join(Medication, Medication.id == Schedule.medication_id)
        .join(Profile, Profile.id == Medication.profile_id)
        .where(Schedule.id == schedule_id, Profile.owner_user_id == user_id)
    )
    return await session.scalar(_finish(stmt, Schedule, include_deleted, lock))


async def load_dose_event(
    session: AsyncSession, user_id: uuid.UUID, event_id: uuid.UUID
) -> DoseEvent | None:
    return await session.scalar(
        select(DoseEvent)
        .join(Profile, Profile.id == DoseEvent.profile_id)
        .where(DoseEvent.id == event_id, Profile.owner_user_id == user_id)
    )


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


async def list_dose_events(
    session: AsyncSession,
    user_id: uuid.UUID,
    *,
    profile_id: uuid.UUID | None,
    medication_id: uuid.UUID | None,
    since: datetime | None,
    until: datetime | None,
    limit: int,
) -> Sequence[DoseEvent]:
    stmt = (
        select(DoseEvent)
        .join(Profile, Profile.id == DoseEvent.profile_id)
        .where(Profile.owner_user_id == user_id)
    )
    if profile_id is not None:
        stmt = stmt.where(DoseEvent.profile_id == profile_id)
    if medication_id is not None:
        stmt = stmt.where(DoseEvent.medication_id == medication_id)
    if since is not None:
        stmt = stmt.where(DoseEvent.at >= since)
    if until is not None:
        stmt = stmt.where(DoseEvent.at < until)
    rows = await session.scalars(stmt.order_by(DoseEvent.at.desc(), DoseEvent.id).limit(limit))
    return rows.all()


# --- writes: common -----------------------------------------------------------


def _stamp(row: Profile | Medication | Schedule, ctx: WriteContext) -> None:
    row.version += 1
    row.client_updated_at = ctx.client_updated_at
    row.updated_by_device = ctx.device
    row.updated_at = utcnow()


def _tombstone_values(ctx: WriteContext, entity: Any) -> dict[str, Any]:
    now = utcnow()
    return {
        "deleted_at": now,
        "updated_at": now,
        "version": entity.version + 1,
        "client_updated_at": ctx.client_updated_at,
        "updated_by_device": ctx.device,
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
            .values(**_tombstone_values(ctx, Schedule))
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
    )
    await _insert(session, row)
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
    row.deleted_at = utcnow()
    _stamp(row, ctx)
    await record_change(session, ctx.user_id, "profile", row.id, "delete")
    med_ids = (
        await session.scalars(
            update(Medication)
            .where(Medication.profile_id == row.id, Medication.deleted_at.is_(None))
            .values(**_tombstone_values(ctx, Medication))
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
    await _insert(session, row)
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
    row.deleted_at = utcnow()
    _stamp(row, ctx)
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
    await _insert(session, row)
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
    row.deleted_at = utcnow()
    _stamp(row, ctx)
    await record_change(session, ctx.user_id, "schedule", row.id, "delete")


# --- dose events --------------------------------------------------------------


def _same_event(row: DoseEvent, data: DoseEventData) -> bool:
    return (
        row.medication_id == data.medication_id
        and row.type == data.type
        and row.at == data.at
        and row.occurrence_key == data.occurrence_key
        and row.target_event_id == data.target_event_id
        and row.note == data.note
    )


def idempotency_conflict() -> AppError:
    return AppError(
        409, "idempotency_conflict", "A different dose event with this id already exists"
    )


async def record_dose_event(
    session: AsyncSession,
    user_id: uuid.UUID,
    device_id: str | None,
    event_id: uuid.UUID,
    data: DoseEventData,
) -> tuple[DoseEvent, bool]:
    """Append a dose event. Returns ``(event, created)``.

    Idempotent by id: an identical replay returns the stored event with
    ``created=False``; a different payload under the same id is a conflict.
    """
    existing = await session.scalar(select(DoseEvent).where(DoseEvent.id == event_id))
    if existing is not None:
        owned = await load_dose_event(session, user_id, event_id)
        if owned is None or not _same_event(owned, data):
            raise idempotency_conflict()
        return owned, False

    # Tombstoned medications still accept events: an offline device may record
    # a dose before it learns about the deletion, and history must not be lost.
    medication = await load_medication(session, user_id, data.medication_id, include_deleted=True)
    if medication is None:
        raise AppError(404, "not_found", "Not found")

    if data.target_event_id is not None:
        target = await load_dose_event(session, user_id, data.target_event_id)
        if target is None or target.medication_id != medication.id or target.type == "undo":
            raise AppError(
                422, "invalid_undo_target", "undo must target a non-undo event of this medication"
            )

    if data.occurrence_key is not None:
        schedule = await load_schedule(
            session, user_id, occurrence_schedule_id(data.occurrence_key), include_deleted=True
        )
        # Unknown schedules are accepted (it may not be synced yet); a known
        # schedule must belong to the same medication.
        if schedule is not None and schedule.medication_id != medication.id:
            raise AppError(
                422,
                "invalid_occurrence_key",
                "occurrence_key refers to a schedule of another medication",
            )

    row = DoseEvent(
        id=event_id,
        profile_id=medication.profile_id,
        medication_id=medication.id,
        occurrence_key=data.occurrence_key,
        type=data.type,
        target_event_id=data.target_event_id,
        at=data.at,
        device_id=device_id,
        note=data.note,
        recorded_at=utcnow(),
    )
    try:
        await _insert(session, row)
    except AppError:
        # Lost a race against an identical concurrent insert?
        again = await load_dose_event(session, user_id, event_id)
        if again is not None and _same_event(again, data):
            return again, False
        raise idempotency_conflict() from None
    await record_change(session, user_id, "dose_event", row.id, "upsert")
    return row, True
