"""The claim step of push delivery: lock due rows, re-check access, lease them (ADR 0008 §6).

``SELECT ... FOR UPDATE SKIP LOCKED`` takes up to ``PUSH_BATCH_SIZE`` due rows, so concurrent
workers never claim the same row, and the *same query* decides whether the recipient may still
be told: access changes between enqueue and send (a revoked grant, a leave, a narrowing to
``hidden``, an archive, a deletion request), and a push that outlives it would disclose what the
relative is no longer allowed to see. Rows that fail the check are ``dropped`` with
``access_changed`` and never reach a sender; stale rows and rows out of attempts are dropped
too. The rest get ``attempts + 1`` and a *lease* (``next_attempt_at`` moves
``PUSH_CLAIM_LEASE_SECONDS`` ahead) and the transaction commits, so no database connection or
row lock is held while talking to providers.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import (
    ColumnElement,
    Row,
    Select,
    Uuid,
    and_,
    cast,
    exists,
    not_,
    or_,
    select,
    update,
)
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from app.config import Settings
from app.db.alerts import MissedDoseAlert
from app.db.models import Medication, Profile, User
from app.db.push import PushOutbox, PushToken
from app.db.relatives import ProfileGrant
from app.observability import get_logger
from app.push.base import PushProvider
from app.services.access import grant_is_active
from app.services.push_outbox import ACCESS_CHANGED

_log = get_logger("pillpal.push")

STALE = "stale"
MAX_ATTEMPTS = "max_attempts"
LINK_KINDS = ("link_accepted", "link_restored")


@dataclass(frozen=True)
class Claimed:
    id: int
    token_id: uuid.UUID
    provider: PushProvider
    token: str
    apns_environment: str | None
    payload: dict[str, Any]
    attempts: int  # including this attempt
    created_at: datetime


@dataclass(frozen=True)
class Claim:
    """What one claim decided: rows to send now, and rows dropped (reason -> count)."""

    items: list[Claimed]
    dropped: dict[str, int]

    @property
    def size(self) -> int:
        return len(self.items) + sum(self.dropped.values())


ALERT_KINDS = ("missed", "resolved")


def _may_still_receive(
    recipient: Any, subject_owner: Any, alert_medication: Any
) -> ColumnElement[bool]:
    """Whether the recipient may still be told about the row's profile and medication.

    Same rules as the read paths (``app.services.access``): recipient and subject owner are
    not pending deletion, the profile is live and not archived, the recipient owns it or holds
    an *active* grant, and a ``hidden`` medication goes only to full-access roles (owner,
    guardian). A tombstoned medication is gone. A ``link_*`` notice also needs its grant
    (payload ``g``) to be active.
    """
    holds_grant = exists().where(
        ProfileGrant.profile_id == Profile.id,
        ProfileGrant.grantee_user_id == PushOutbox.recipient_user_id,
        grant_is_active(),
    )
    full_access = or_(
        Profile.owner_user_id == PushOutbox.recipient_user_id,
        exists().where(
            ProfileGrant.profile_id == Profile.id,
            ProfileGrant.grantee_user_id == PushOutbox.recipient_user_id,
            ProfileGrant.role == "guardian",
            grant_is_active(),
        ),
    )
    medication_ok = or_(
        PushOutbox.subject_medication_id.is_(None),
        and_(
            Medication.id.is_not(None),
            Medication.profile_id == Profile.id,
            Medication.deleted_at.is_(None),
            or_(Medication.privacy != "hidden", full_access),
        ),
    )
    # A link notice is about one grant: if it was revoked, left or became inactive meanwhile,
    # telling the owner about the relative would be stale at best.
    grant_ok = or_(
        PushOutbox.kind.not_in(LINK_KINDS),
        exists().where(
            ProfileGrant.id == cast(PushOutbox.payload["g"].astext, Uuid),
            ProfileGrant.profile_id == Profile.id,
            grant_is_active(),
        ),
    )
    # missed / resolved are about an alert, whose medication may have been narrowed since the row
    # was queued: a projected role needs ``shared`` if the payload names the medication, and
    # anything but ``hidden`` otherwise; and a ``missed`` still needs the grantee's opt-in.
    # (An alert row that is gone, retention or purge, leaves the columns' check above.)
    named = PushOutbox.payload["m"].astext.is_not(None)
    alert_privacy_ok = or_(
        full_access,
        and_(named, alert_medication.privacy == "shared"),
        and_(not_(named), alert_medication.privacy != "hidden"),
    )
    opted_in = or_(
        Profile.owner_user_id == PushOutbox.recipient_user_id,
        exists().where(
            ProfileGrant.profile_id == Profile.id,
            ProfileGrant.grantee_user_id == PushOutbox.recipient_user_id,
            ProfileGrant.notify_missed,
            grant_is_active(),
        ),
    )
    alert_ok = or_(
        PushOutbox.kind.not_in(ALERT_KINDS),
        MissedDoseAlert.id.is_(None),
        and_(
            alert_medication.deleted_at.is_(None),
            alert_privacy_ok,
            or_(PushOutbox.kind != "missed", opted_in),
        ),
    )
    return and_(
        alert_ok,
        grant_ok,
        recipient.deletion_requested_at.is_(None),
        Profile.id.is_not(None),
        Profile.deleted_at.is_(None),
        Profile.archived_at.is_(None),
        subject_owner.deletion_requested_at.is_(None),
        or_(Profile.owner_user_id == PushOutbox.recipient_user_id, holds_grant),
        medication_ok,
    )


def _due_rows(settings: Settings, now: datetime) -> Select[Any]:
    recipient, subject_owner = aliased(User), aliased(User)
    alert_medication = aliased(Medication)
    return (
        select(
            PushOutbox.id,
            PushOutbox.push_token_id,
            PushOutbox.payload,
            PushOutbox.attempts,
            PushOutbox.created_at,
            PushToken.provider,
            PushToken.token,
            PushToken.apns_environment,
            _may_still_receive(recipient, subject_owner, alert_medication).label("allowed"),
        )
        .join(
            PushToken,
            and_(
                PushToken.id == PushOutbox.push_token_id,
                # The token must be the recipient's own, whatever wrote the row.
                PushToken.user_id == PushOutbox.recipient_user_id,
            ),
        )
        .join(recipient, recipient.id == PushOutbox.recipient_user_id)
        .outerjoin(Profile, Profile.id == PushOutbox.subject_profile_id)
        .outerjoin(subject_owner, subject_owner.id == Profile.owner_user_id)
        .outerjoin(Medication, Medication.id == PushOutbox.subject_medication_id)
        .outerjoin(
            MissedDoseAlert,
            and_(
                PushOutbox.kind.in_(ALERT_KINDS),
                MissedDoseAlert.id == cast(PushOutbox.payload["a"].astext, Uuid),
            ),
        )
        .outerjoin(alert_medication, alert_medication.id == MissedDoseAlert.medication_id)
        .where(PushOutbox.status == "pending", PushOutbox.next_attempt_at <= now)
        .order_by(PushOutbox.next_attempt_at, PushOutbox.id)
        .limit(settings.push_batch_size)
        .with_for_update(of=PushOutbox, skip_locked=True)
    )


def _classify(
    due: Sequence[Row[Any]], settings: Settings, now: datetime
) -> tuple[list[Claimed], dict[str, list[int]]]:
    """Split the locked rows into what to send and what to drop (reason -> row ids)."""
    stale_before = now - timedelta(seconds=settings.push_stale_after_seconds)
    claimed: list[Claimed] = []
    drops: dict[str, list[int]] = {}
    for row in due:
        if not row.allowed:
            drops.setdefault(ACCESS_CHANGED, []).append(row.id)
        elif row.created_at <= stale_before:
            drops.setdefault(STALE, []).append(row.id)
        elif row.attempts >= settings.push_max_attempts:
            drops.setdefault(MAX_ATTEMPTS, []).append(row.id)
        else:
            claimed.append(
                Claimed(
                    row.id,
                    row.push_token_id,
                    row.provider,
                    row.token,
                    row.apns_environment,
                    row.payload,
                    row.attempts + 1,
                    row.created_at,
                )
            )
    return claimed, drops


async def claim_batch(session: AsyncSession, settings: Settings, now: datetime) -> Claim:
    """Claim a batch (see the module docstring); commits. Rows that may not be sent are dropped."""
    due = (await session.execute(_due_rows(settings, now))).all()
    claimed, drops = _classify(due, settings, now)
    for reason, ids in drops.items():
        await session.execute(
            update(PushOutbox)
            .where(PushOutbox.id.in_(ids))
            .values(status="dropped", last_error_code=reason)
            .execution_options(synchronize_session=False)
        )
    if claimed:
        await session.execute(
            update(PushOutbox)
            .where(PushOutbox.id.in_([c.id for c in claimed]))
            .values(
                attempts=PushOutbox.attempts + 1,
                next_attempt_at=now + timedelta(seconds=settings.push_claim_lease_seconds),
            )
            .execution_options(synchronize_session=False)
        )
    await session.commit()
    for reason, ids in drops.items():
        _log.info("push_dropped", reason=reason, count=len(ids))
    return Claim(claimed, {reason: len(ids) for reason, ids in drops.items()})
