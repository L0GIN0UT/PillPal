"""Pushes of one missed-dose alert: who gets which payload (ADR 0007 §2-§3, ADR 0008 §2).

The detector (``missed``) and the resolution of a late mark (``resolved``) use the same rule, so
``resolved`` recipients are recomputed, never read back from the outbox (whose rows are consumed
and purged). Payloads carry ids and enums only; ``m`` (the medication) is withheld from
projected recipients of ``anonymous`` medications, who see time and status only.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime

from app.domain.missed import GrantInfo, include_medication_id, recipients_of
from app.push.base import PushPayload
from app.services.push_outbox import OutboxItem


@dataclass(frozen=True, slots=True)
class AlertSubject:
    """What the recipient rule needs to know about one alert."""

    alert_id: uuid.UUID
    profile_id: uuid.UUID
    medication_id: uuid.UUID
    due_at: datetime
    profile_kind: str
    owner_id: uuid.UUID
    privacy: str
    unconfirmed: bool


def push_items(kind: str, subject: AlertSubject, grants: Sequence[GrantInfo]) -> list[OutboxItem]:
    """Outbox items of ``kind`` (``missed`` or ``resolved``) for the alert's recipients."""
    recipients = recipients_of(
        subject.profile_kind, subject.owner_id, grants, subject.due_at, subject.privacy
    )
    items: list[OutboxItem] = []
    for recipient in recipients:
        medication_id = (
            subject.medication_id if include_medication_id(subject.privacy, recipient) else None
        )
        payload = PushPayload.model_validate(
            {
                "t": kind,
                "a": subject.alert_id,
                "p": subject.profile_id,
                "m": medication_id,
                # Only a missed alert can be unconfirmed (and never says when: ADR 0007 §4).
                "s": "u" if subject.unconfirmed and kind == "missed" else None,
            }
        )
        items.append(
            OutboxItem(
                recipient_user_id=recipient.user_id,
                payload=payload,
                ref=str(subject.alert_id),
                subject_profile_id=subject.profile_id,
                subject_medication_id=medication_id,
            )
        )
    return items
