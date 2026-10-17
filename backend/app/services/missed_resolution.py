"""A late ``taken`` / ``skipped`` resolves the alert of its occurrence (ADR 0007 §3).

Called from ``record_dose_event`` in the transaction of the event, under the owner's journal
lock: the detector's batch holds the same lock while it reads events and inserts alerts, so a
late mark either committed before the batch read (no alert) or finds the alert here. The alert
gets ``resolved_at`` and the recipients, recomputed by the same rule as the alert (never read
back from the outbox), get a ``resolved`` push that replaces the notification. A ``missed`` push
is never re-sent: ``resolved_at`` only ever moves from NULL to a value, once.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.alerts import MissedDoseAlert
from app.db.models import DoseEvent, Medication, Profile, User
from app.services.missed_queries import load_grants
from app.services.missed_recipients import AlertSubject, push_items
from app.services.push_outbox import enqueue_many

MARK_TYPES = frozenset({"taken", "skipped"})


async def resolve_alert_for_mark(session: AsyncSession, event: DoseEvent, now: datetime) -> bool:
    """Resolve the alert of ``event``'s occurrence, if any; returns whether one was resolved.

    The caller holds the owner's journal lock and commits. A mark with no occurrence key, a
    snooze or an undo resolves nothing (an undo can only make an alert more true).
    """
    if event.type not in MARK_TYPES or event.occurrence_key is None:
        return False
    row = (
        await session.execute(
            update(MissedDoseAlert)
            .where(
                MissedDoseAlert.profile_id == event.profile_id,
                MissedDoseAlert.occurrence_key == event.occurrence_key,
                MissedDoseAlert.resolved_at.is_(None),
            )
            .values(resolved_at=now)
            .returning(MissedDoseAlert.id, MissedDoseAlert.medication_id, MissedDoseAlert.due_at)
        )
    ).one_or_none()
    if row is None:
        return False
    alert_id, medication_id, due_at = row
    subject = await _subject(session, event, alert_id, medication_id, due_at)
    if subject is not None:
        grants = await load_grants(session, [subject.profile_id])
        await enqueue_many(
            session, push_items("resolved", subject, grants.get(subject.profile_id, [])), now=now
        )
    return True


async def _subject(
    session: AsyncSession,
    event: DoseEvent,
    alert_id: uuid.UUID,
    medication_id: uuid.UUID,
    due_at: datetime,
) -> AlertSubject | None:
    """The alert as the recipient rule sees it now, or ``None`` when nobody may be told: the
    profile is gone or an archive, or its owner has asked for deletion (ADR 0010)."""
    info = (
        await session.execute(
            select(
                Profile.kind, Profile.owner_user_id, Medication.privacy, User.deletion_requested_at
            )
            .join(Medication, Medication.profile_id == Profile.id)
            .join(User, User.id == Profile.owner_user_id)
            .where(
                Profile.id == event.profile_id,
                Medication.id == medication_id,
                Profile.deleted_at.is_(None),
                Profile.archived_at.is_(None),
            )
        )
    ).one_or_none()
    if info is None or info.deletion_requested_at is not None:
        return None
    return AlertSubject(
        alert_id=alert_id,
        profile_id=event.profile_id,
        medication_id=medication_id,
        due_at=due_at,
        profile_kind=info.kind,
        owner_id=info.owner_user_id,
        privacy=info.privacy,
        unconfirmed=False,
    )
