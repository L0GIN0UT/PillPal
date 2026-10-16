"""Profiles, medications and schedules: writes (reads are in ``entity_loaders``).

Reads are filtered by the caller's full access in the SQL query, so a foreign id
behaves exactly like a missing one (``app.services.entity_loaders``, re-exported
here). Every write bumps ``version``, stamps the last-write-wins key and is
journaled in ``sync_changes`` into the profile's scope within the caller's
transaction; callers take the journal lock of the scope's owner first
(``app.services.changes.lock_journal``) and commit.

Deletes are tombstones without content: ids, version and the conflict key
stay, names/notes/rules are erased. Deleting a parent tombstones its children.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import DateTime, Text, case, literal, null, select, tuple_, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.models import (
    MEDICATION_CONTENT,
    PROFILE_CONTENT,
    SCHEDULE_CONTENT,
    Medication,
    Profile,
    Schedule,
)
from app.errors import AppError, not_found
from app.services.changes import (
    record_change,
    record_changes,
    rejournal_dose_events,
)
from app.services.entity_loaders import (
    Lock,
    list_medications,
    list_profiles,
    list_schedules,
    load_medication,
    load_profile,
    load_schedule,
)
from app.services.scope_limit import ensure_scope_room, lock_access

__all__ = [
    "Lock",
    "WriteContext",
    "already_exists",
    "create_medication",
    "create_profile",
    "create_schedule",
    "delete_medication",
    "delete_profile",
    "delete_schedule",
    "insert_new",
    "list_medications",
    "list_profiles",
    "list_schedules",
    "load_medication",
    "load_profile",
    "load_schedule",
    "update_medication",
    "update_profile",
    "update_schedule",
    "utcnow",
]

ONE_MICROSECOND = timedelta(microseconds=1)
UNIQUE_VIOLATION = "23505"


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
    session: AsyncSession,
    ctx: WriteContext,
    profile_id: uuid.UUID,
    medication_ids: Sequence[uuid.UUID],
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
    await record_changes(session, profile_id, "schedule", list(ids), "delete")


# --- profiles -----------------------------------------------------------------


async def create_profile(
    session: AsyncSession,
    ctx: WriteContext,
    *,
    settings: Settings,
    profile_id: uuid.UUID,
    display_name: str,
    timezone: str,
    missed_alert_minutes: int | None = None,
    missed_alerts_enabled: bool | None = None,
) -> Profile:
    """Create a managed profile; ``None`` leaves a missed-alert setting at its default."""
    await lock_access(session, [ctx.user_id])
    await ensure_scope_room(session, settings, ctx.user_id)
    alert_settings = {
        "missed_alert_minutes": missed_alert_minutes,
        "missed_alerts_enabled": missed_alerts_enabled,
    }
    row = Profile(
        id=profile_id,
        owner_user_id=ctx.user_id,
        kind="managed",
        display_name=display_name,
        timezone=timezone,
        version=1,
        client_updated_at=ctx.client_updated_at,
        updated_by_device=ctx.device,
        **{key: value for key, value in alert_settings.items() if value is not None},
    )
    await insert_new(session, row)
    await record_change(session, row.id, "profile", row.id, "upsert")
    return row


async def update_profile(
    session: AsyncSession, ctx: WriteContext, row: Profile, changes: dict[str, Any]
) -> Profile:
    for key, value in changes.items():
        setattr(row, key, value)
    _stamp(row, ctx)
    await record_change(session, row.id, "profile", row.id, "upsert")
    return row


async def delete_profile(session: AsyncSession, ctx: WriteContext, row: Profile) -> None:
    if row.kind == "self":
        raise AppError(409, "self_profile_protected", "The self profile cannot be deleted")
    _tombstone_row(row, ctx, PROFILE_CONTENT)
    await record_change(session, row.id, "profile", row.id, "delete")
    med_ids = (
        await session.scalars(
            update(Medication)
            .where(Medication.profile_id == row.id, Medication.deleted_at.is_(None))
            .values(**_tombstone_values(ctx, Medication, MEDICATION_CONTENT))
            .returning(Medication.id)
            .execution_options(synchronize_session=False)
        )
    ).all()
    await record_changes(session, row.id, "medication", list(med_ids), "delete")
    all_med_ids = (
        await session.scalars(select(Medication.id).where(Medication.profile_id == row.id))
    ).all()
    await _tombstone_schedules_of(session, ctx, row.id, all_med_ids)


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
    await record_change(session, profile_id, "medication", row.id, "upsert")
    return row


async def update_medication(
    session: AsyncSession, ctx: WriteContext, row: Medication, fields: dict[str, Any]
) -> Medication:
    previous_privacy = row.privacy
    for key, value in fields.items():
        setattr(row, key, value)
    _stamp(row, ctx)
    if row.privacy == previous_privacy:
        await record_change(session, row.profile_id, "medication", row.id, "upsert")
    else:
        await _journal_privacy_change(session, row, previous_privacy)
    return row


async def _journal_privacy_change(
    session: AsyncSession, row: Medication, previous_privacy: str
) -> None:
    """Re-deliver a medication whose privacy level changed (ADR 0006 §4).

    Relatives see a different projection of the medication and of its schedules, so
    both are journaled again. Dose events look the same for ``shared`` and
    ``anonymous``: they are journaled again only when they become visible at all
    (they are skipped on the way out, so narrowing needs nothing).
    """
    await record_change(session, row.profile_id, "medication", row.id, "privacy")
    schedule_ids = (
        await session.scalars(
            select(Schedule.id)
            .where(Schedule.medication_id == row.id, Schedule.deleted_at.is_(None))
            .order_by(Schedule.created_at, Schedule.id)
        )
    ).all()
    await record_changes(session, row.profile_id, "schedule", list(schedule_ids), "upsert")
    if previous_privacy == "hidden":
        await rejournal_dose_events(session, row.profile_id, row.id)


async def delete_medication(session: AsyncSession, ctx: WriteContext, row: Medication) -> None:
    _tombstone_row(row, ctx, MEDICATION_CONTENT)
    await record_change(session, row.profile_id, "medication", row.id, "delete")
    await _tombstone_schedules_of(session, ctx, row.profile_id, [row.id])


# --- schedules ----------------------------------------------------------------


async def _profile_of(session: AsyncSession, medication_id: uuid.UUID) -> uuid.UUID:
    """The journal scope of a schedule is its medication's profile, never a caller's claim."""
    profile_id = await session.scalar(
        select(Medication.profile_id).where(Medication.id == medication_id)
    )
    if profile_id is None:  # pragma: no cover - the caller loaded the medication or the schedule
        raise not_found()
    return profile_id


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
    await record_change(
        session, await _profile_of(session, medication_id), "schedule", row.id, "upsert"
    )
    return row


async def update_schedule(
    session: AsyncSession, ctx: WriteContext, row: Schedule, rule: dict[str, Any]
) -> Schedule:
    row.rule = rule
    _stamp(row, ctx)
    scope = await _profile_of(session, row.medication_id)
    await record_change(session, scope, "schedule", row.id, "upsert")
    return row


async def delete_schedule(session: AsyncSession, ctx: WriteContext, row: Schedule) -> None:
    _tombstone_row(row, ctx, SCHEDULE_CONTENT)
    scope = await _profile_of(session, row.medication_id)
    await record_change(session, scope, "schedule", row.id, "delete")
