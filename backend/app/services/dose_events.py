"""Dose events: append-only, idempotent by client-generated id (TZ §2.4).

Reads are scoped to full access (owner, guardian) in SQL like every other entity.
Writes are journaled into the profile's scope; callers take the journal lock of
the scope's owner first and commit.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import DoseEvent, Medication, Profile
from app.errors import AppError
from app.schemas.entities import DoseEventData, occurrence_schedule_id
from app.services.access import has_full_access
from app.services.changes import record_change
from app.services.entities import insert_new, load_medication, load_schedule, utcnow
from app.services.missed_resolution import resolve_alert_for_mark


async def load_dose_event(
    session: AsyncSession, user_id: uuid.UUID, event_id: uuid.UUID
) -> DoseEvent | None:
    return await session.scalar(
        select(DoseEvent)
        .join(Profile, Profile.id == DoseEvent.profile_id)
        .where(DoseEvent.id == event_id, has_full_access(user_id))
    )


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
        .where(has_full_access(user_id))
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


def _same_event(row: DoseEvent, data: DoseEventData) -> bool:
    return (
        row.medication_id == data.medication_id
        and row.type == data.type
        and row.at == data.at
        and row.occurrence_key == data.occurrence_key
        and row.target_event_id == data.target_event_id
        and row.note == data.note
        and row.snooze_until == data.snooze_until
    )


def idempotency_conflict() -> AppError:
    return AppError(
        409, "idempotency_conflict", "A different dose event with this id already exists"
    )


async def _check_references(
    session: AsyncSession, user_id: uuid.UUID, medication: Medication, data: DoseEventData
) -> None:
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
    await _check_references(session, user_id, medication, data)

    recorded_at = utcnow()
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
        snooze_until=data.snooze_until,
        recorded_at=recorded_at,
    )
    try:
        await insert_new(session, row)
    except AppError:
        # Lost a race against an identical concurrent insert?
        again = await load_dose_event(session, user_id, event_id)
        if again is not None and _same_event(again, data):
            return again, False
        raise idempotency_conflict() from None
    await record_change(session, row.profile_id, "dose_event", row.id, "upsert")
    # Same transaction, same owner lock as the detector's batch (ADR 0007 §3).
    await resolve_alert_for_mark(session, row, recorded_at)
    return row, True
