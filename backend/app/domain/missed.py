"""Pure rules of the missed-dose detector (ADR 0007): windows, final due, variant, recipients.

No IO and no clock: the service (``app.services.missed_doses``) reads the database and calls
these functions. The mark, snooze and ``missed`` semantics are *not* restated here; they come from
``app.domain.dose_state`` (``docs/spec/dose-state.md``), and occurrences from the schedule engine.
"""

from __future__ import annotations

import re
import uuid
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Final

from app.domain.dose_state import OccurrenceState
from app.domain.schedule import ScheduleRule, load_zone, local_to_utc

_TIME_PART: Final = re.compile(r"^(\d{2}):(\d{2})$")
SELF_KIND: Final = "self"
MANAGED_KIND: Final = "managed"
GUARDIAN_ROLE: Final = "guardian"
HIDDEN: Final = "hidden"
SHARED: Final = "shared"


# --- windows -------------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class DetectionWindow:
    """The half-open span ``[start, end)`` one tick looks at (ADR 0007 §2)."""

    start: datetime
    end: datetime
    skipped: timedelta  # downtime beyond the catch-up horizon that nothing will look at


def next_window(
    watermark: datetime, now: datetime, *, max_window: timedelta, max_catchup: timedelta
) -> DetectionWindow | None:
    """The window after ``watermark``: at most ``max_window`` long, never ending after ``now``.

    After more than ``max_catchup`` of downtime the start jumps to ``now - max_catchup`` and the
    jumped span is reported as ``skipped`` (a flood of stale alarms helps nobody). ``None`` when
    the watermark is not behind ``now``.
    """
    if now <= watermark:
        return None
    start, skipped = watermark, timedelta(0)
    if now - start > max_catchup:
        skipped = now - max_catchup - start
        start = now - max_catchup
    return DetectionWindow(start, min(now, start + max_window), skipped)


# --- the decision --------------------------------------------------------------------------


def alert_due_at(
    state: OccurrenceState,
    occurrence_at: datetime,
    grace: timedelta,
    window: DetectionWindow,
    *,
    late_undo: bool,
    horizon: timedelta,
) -> datetime | None:
    """The final due instant when this occurrence must be alerted now, else ``None``.

    Each occurrence is counted once, at its final ``due + grace``: when that instant lies in
    the window. ``late_undo`` is the candidate-C case (an undo recorded in this window made the
    occurrence unmarked or due earlier after its own window had passed): it alerts whenever
    ``due + grace`` is already behind us, but not for occurrences older than ``horizon`` (undoing
    last week's mark in the history must not page relatives about last week).
    """
    if state.mark is not None:
        return None
    due = state.due_at(occurrence_at)
    fires_at = due + grace
    if window.start <= fires_at < window.end:
        return due
    if late_undo and window.end - horizon <= fires_at < window.end:
        return due
    return None


def occurrence_instant(rule: ScheduleRule, schedule_id: str, tz: str, key: str) -> datetime | None:
    """The engine's instant of occurrence ``key``, or ``None`` if the rule has no such occurrence.

    Snoozes and undos name occurrences by key only. A key is trusted no further than the rule
    confirms it: right schedule, a real date in the course on a qualifying day, an existing slot.
    """
    prefix = f"{schedule_id}/"
    if not key.startswith(prefix):
        return None
    day_text, separator, time_text = key[len(prefix) :].partition("T")
    parts = _TIME_PART.fullmatch(time_text)
    if not separator or parts is None:
        return None
    try:
        day = date.fromisoformat(day_text)
    except ValueError:
        return None
    if day.isoformat() != day_text or not rule.occurs_on(day):
        return None
    if not any(slot.time == time_text for slot in rule.times):
        return None
    return local_to_utc(day, int(parts.group(1)), int(parts.group(2)), load_zone(tz))


def is_unconfirmed(
    profile_kind: str, device_last_seen: Iterable[datetime], occurrence_at: datetime
) -> bool:
    """D5: a self profile whose owner's devices were all last seen before the occurrence.

    The server then only knows that nobody confirmed the dose, not that it was skipped.
    Managed profiles are always ``missed`` (the guardians' devices are not the subject's).
    """
    if profile_kind != SELF_KIND:
        return False
    return all(seen < occurrence_at for seen in device_last_seen)


# --- recipients ----------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class GrantInfo:
    """An *active* grant on the profile (the caller applies ``grant_is_active``)."""

    user_id: uuid.UUID
    role: str
    created_at: datetime
    notify_missed: bool


@dataclass(frozen=True, slots=True)
class Recipient:
    user_id: uuid.UUID
    full_access: bool  # owner or guardian: sees ``hidden`` and ``anonymous`` medications whole


def recipients_of(
    profile_kind: str,
    owner_id: uuid.UUID,
    grants: Sequence[GrantInfo],
    due_at: datetime,
    privacy: str,
) -> list[Recipient]:
    """Who is told about an alert on a medication of ``privacy`` (ADR 0007 §2, ADR 0005 §2).

    * the owner of a *managed* profile that has co-guardians (a self owner has local reminders);
    * grantees with ``notify_missed`` whose grant existed when the dose was due (a new link does
      not flood the grantee with old alerts); a guardian who muted alerts stays muted but still
      counts as a co-guardian for the owner;
    * ``hidden`` medications go to full-access recipients only.
    """
    result: list[Recipient] = []
    if profile_kind == MANAGED_KIND and any(g.role == GUARDIAN_ROLE for g in grants):
        result.append(Recipient(owner_id, full_access=True))
    for grant in grants:
        if not grant.notify_missed or grant.created_at > due_at:
            continue
        full_access = grant.role == GUARDIAN_ROLE
        if privacy == HIDDEN and not full_access:
            continue
        result.append(Recipient(grant.user_id, full_access))
    return result


def include_medication_id(privacy: str, recipient: Recipient) -> bool:
    """Whether the push carries ``m`` (ADR 0008): the device looks the name up locally.

    Full-access recipients may know every medication. A projected recipient gets ``m`` only for
    ``shared`` ones: for ``anonymous`` they see time and status, so the id (which would let the
    device resolve a name it does not have anyway) is withheld and the text stays generic.
    """
    return recipient.full_access or privacy == SHARED
