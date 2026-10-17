"""Reads of the missed-dose detector (ADR 0007 §2).

Every function is one statement whatever the number of profiles it is given (arrays are bound as
one parameter, never one parameter per id), so a batch costs a constant number of statements.
Eligibility and access reuse the predicates of ``app.services.access``; nothing here restates
the dose-state or schedule semantics.
"""

from __future__ import annotations

import uuid
from collections.abc import Collection, Iterable
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Any, cast

from sqlalchemy import (
    ColumnElement,
    Interval,
    Text,
    Uuid,
    and_,
    any_,
    bindparam,
    exists,
    func,
    not_,
    or_,
    select,
)
from sqlalchemy.dialects.postgresql import ARRAY
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from app.db.models import Device, DoseEvent, Medication, Profile, Schedule, User
from app.db.relatives import ProfileGrant
from app.domain.dose_state import DoseEvent as StateEvent
from app.domain.dose_state import DoseEventType
from app.domain.missed import DetectionWindow, GrantInfo
from app.limits import MAX_MISSED_ALERT_MINUTES, MIN_MISSED_ALERT_MINUTES
from app.services.access import grant_is_active


def in_array(column: Any, values: Iterable[Any], element: Any) -> ColumnElement[bool]:
    """``column = ANY(:values)`` with the whole list as one bound array."""
    return cast(
        "ColumnElement[bool]", column == any_(bindparam(None, list(values), type_=ARRAY(element)))
    )


@dataclass(frozen=True, slots=True)
class ProfileInfo:
    id: uuid.UUID
    owner_id: uuid.UUID
    kind: str
    timezone: str
    grace: timedelta


@dataclass(frozen=True, slots=True)
class ScheduleInfo:
    id: uuid.UUID
    rule: dict[str, Any]
    created_at: datetime
    medication_id: uuid.UUID
    profile_id: uuid.UUID
    tz_mode: str
    fixed_tz: str | None
    privacy: str


# --- eligibility ---------------------------------------------------------------------------


def _eligible() -> Any:
    """Profiles worth looking at: live, not archived, owner not pending deletion, alerts on, and
    somebody to tell (a co-guardian of a managed profile, or a grantee who wants alerts)."""
    pending_owners = select(User.id).where(User.deletion_requested_at.is_not(None))
    has_co_guardian = exists().where(
        ProfileGrant.profile_id == Profile.id,
        ProfileGrant.role == "guardian",
        grant_is_active(),
    )
    has_notified_grantee = exists().where(
        ProfileGrant.profile_id == Profile.id,
        ProfileGrant.notify_missed,
        grant_is_active(),
    )
    return and_(
        Profile.deleted_at.is_(None),
        Profile.archived_at.is_(None),
        Profile.missed_alerts_enabled,
        not_(Profile.owner_user_id.in_(pending_owners)),
        or_(and_(Profile.kind == "managed", has_co_guardian), has_notified_grantee),
    )


async def eligible_page(
    session: AsyncSession, after: uuid.UUID | None, limit: int
) -> list[tuple[uuid.UUID, uuid.UUID]]:
    """``(profile id, owner id)`` of the next eligible profiles by id (keyset paging)."""
    stmt = select(Profile.id, Profile.owner_user_id).where(_eligible())
    if after is not None:
        stmt = stmt.where(Profile.id > after)
    rows = await session.execute(stmt.order_by(Profile.id).limit(limit))
    return [(row[0], row[1]) for row in rows]


async def eligible_among(
    session: AsyncSession, profile_ids: Collection[uuid.UUID]
) -> list[ProfileInfo]:
    """The profiles of ``profile_ids`` that are still eligible (called under the owners' locks)."""
    rows = await session.execute(
        select(
            Profile.id,
            Profile.owner_user_id,
            Profile.kind,
            Profile.timezone,
            Profile.missed_alert_minutes,
        ).where(in_array(Profile.id, profile_ids, Uuid), _eligible())
    )
    return [ProfileInfo(r[0], r[1], r[2], r[3], timedelta(minutes=r[4])) for r in rows]


# --- candidates B and C --------------------------------------------------------------------


async def snoozed_keys(
    session: AsyncSession, window: DetectionWindow, profile_ids: Collection[uuid.UUID]
) -> set[tuple[uuid.UUID, str]]:
    """Candidate B: ``(profile, key)`` of snoozes whose ``snooze_until + grace`` is in the window.

    The grace is the profile's, so the partial index is used for a superset range (any grace
    from the CHECK bounds) and the exact condition filters the few rows it returns.
    """
    grace = func.make_interval(0, 0, 0, 0, 0, Profile.missed_alert_minutes, type_=Interval)
    low = window.start - timedelta(minutes=MAX_MISSED_ALERT_MINUTES)
    high = window.end - timedelta(minutes=MIN_MISSED_ALERT_MINUTES)
    rows = await session.execute(
        select(DoseEvent.profile_id, DoseEvent.occurrence_key)
        .join(Profile, Profile.id == DoseEvent.profile_id)
        .where(
            DoseEvent.type == "snoozed",
            DoseEvent.occurrence_key.is_not(None),
            DoseEvent.snooze_until >= low,
            DoseEvent.snooze_until < high,
            DoseEvent.snooze_until + grace >= window.start,
            DoseEvent.snooze_until + grace < window.end,
            in_array(DoseEvent.profile_id, profile_ids, Uuid),
        )
        .distinct()
    )
    return {(row[0], row[1]) for row in rows if row[1] is not None}


async def undone_keys(
    session: AsyncSession, window: DetectionWindow, profile_ids: Collection[uuid.UUID]
) -> set[tuple[uuid.UUID, str]]:
    """Candidate C: ``(profile, key)`` of the targets of undos recorded in the window.

    The undo's own key is not trusted (legacy rows carry none); its target's key is.
    """
    target = aliased(DoseEvent)
    rows = await session.execute(
        select(DoseEvent.profile_id, target.occurrence_key)
        .join(target, target.id == DoseEvent.target_event_id)
        .where(
            DoseEvent.type == "undo",
            DoseEvent.recorded_at >= window.start,
            DoseEvent.recorded_at < window.end,
            target.occurrence_key.is_not(None),
            in_array(DoseEvent.profile_id, profile_ids, Uuid),
        )
        .distinct()
    )
    return {(row[0], row[1]) for row in rows if row[1] is not None}


# --- schedules and events ------------------------------------------------------------------


def _course_overlaps(window: DetectionWindow) -> ColumnElement[bool]:
    """Cheap JSON prefilter of candidate A: the course must reach the window (dates, with the
    engine's own two-day margin and the widest grace and zone offset), and not be as-needed."""
    margin = timedelta(days=3) + timedelta(minutes=MAX_MISSED_ALERT_MINUTES)
    first: date = (window.start - margin).date()
    last: date = (window.end + margin).date()
    end_date = Schedule.rule["end_date"].as_string()
    return and_(
        Schedule.rule["kind"].as_string() != "as_needed",
        Schedule.rule["start_date"].as_string() <= last.isoformat(),
        or_(end_date.is_(None), end_date >= first.isoformat()),
    )


async def load_schedules(
    session: AsyncSession,
    window: DetectionWindow,
    profile_ids: Collection[uuid.UUID],
    extra_schedule_ids: Collection[uuid.UUID],
) -> list[ScheduleInfo]:
    """Live schedules of live medications of the profiles that may have an occurrence to
    alert (A), plus the schedules named by snoozes and undos (B, C)."""
    wanted = _course_overlaps(window)
    if extra_schedule_ids:
        wanted = or_(wanted, in_array(Schedule.id, extra_schedule_ids, Uuid))
    rows = await session.execute(
        select(
            Schedule.id,
            Schedule.rule,
            Schedule.created_at,
            Medication.id,
            Medication.profile_id,
            Medication.tz_mode,
            Medication.fixed_tz,
            Medication.privacy,
        )
        .join(Medication, Medication.id == Schedule.medication_id)
        .where(
            in_array(Medication.profile_id, profile_ids, Uuid),
            Schedule.deleted_at.is_(None),
            Medication.deleted_at.is_(None),
            wanted,
        )
    )
    return [ScheduleInfo(*row) for row in rows]


async def events_of_keys(
    session: AsyncSession, profile_ids: Collection[uuid.UUID], keys: Collection[str]
) -> list[StateEvent]:
    """Every event of the keys, plus the undos that target them (an undo may carry another key).

    Returned in the shape of ``app.domain.dose_state``: the fold is the one contract.
    """
    in_keys = and_(
        in_array(DoseEvent.profile_id, profile_ids, Uuid),
        in_array(DoseEvent.occurrence_key, keys, Text),
    )
    own_ids = select(DoseEvent.id).where(in_keys)
    rows = await session.execute(
        select(
            DoseEvent.id,
            DoseEvent.type,
            DoseEvent.at,
            DoseEvent.occurrence_key,
            DoseEvent.target_event_id,
            DoseEvent.snooze_until,
        ).where(
            in_array(DoseEvent.profile_id, profile_ids, Uuid),
            or_(in_keys, DoseEvent.target_event_id.in_(own_ids)),
        )
    )
    return [
        StateEvent(
            id=str(r[0]),
            type=cast(DoseEventType, r[1]),
            at=r[2],
            occurrence_key=r[3],
            target_event_id=None if r[4] is None else str(r[4]),
            snooze_until=r[5],
        )
        for r in rows
    ]


# --- devices and grants --------------------------------------------------------------------


async def last_seen_by_owner(
    session: AsyncSession, owner_ids: Collection[uuid.UUID]
) -> dict[uuid.UUID, datetime]:
    """Newest ``devices.last_seen_at`` per account (an account without devices is absent)."""
    rows = await session.execute(
        select(Device.user_id, func.max(Device.last_seen_at))
        .where(in_array(Device.user_id, owner_ids, Uuid))
        .group_by(Device.user_id)
    )
    return {row[0]: row[1] for row in rows}


async def load_grants(
    session: AsyncSession, profile_ids: Collection[uuid.UUID]
) -> dict[uuid.UUID, list[GrantInfo]]:
    """Active grants per profile (``grant_is_active``: neither side pending deletion)."""
    rows = await session.execute(
        select(
            ProfileGrant.profile_id,
            ProfileGrant.grantee_user_id,
            ProfileGrant.role,
            ProfileGrant.created_at,
            ProfileGrant.notify_missed,
        )
        .join(Profile, Profile.id == ProfileGrant.profile_id)
        .where(in_array(ProfileGrant.profile_id, profile_ids, Uuid), grant_is_active())
        .order_by(ProfileGrant.created_at, ProfileGrant.id)
    )
    grants: dict[uuid.UUID, list[GrantInfo]] = {}
    for profile_id, user_id, role, created_at, notify in rows:
        grants.setdefault(profile_id, []).append(GrantInfo(user_id, role, created_at, notify))
    return grants
