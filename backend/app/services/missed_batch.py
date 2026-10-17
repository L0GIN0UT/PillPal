"""One batch of the missed-dose detector: candidates, decision, alerts, pushes (ADR 0007 §2).

Runs in one transaction, under the journal locks of the batch's owners taken *before* any event
is read, so a late ``taken`` either committed first (no alert) or waits and then resolves the
alert (``app.services.missed_resolution``). The statement count does not depend on the number of
profiles in the batch.

Candidates, each a ``(profile, occurrence key)``:

* **A** the occurrences the schedule engine expands whose ``instant + grace`` is in the window;
* **B** the keys of snoozes whose ``snooze_until + grace`` is in the window;
* **C** the targets of undos recorded in the window (a late undo makes an occurrence unmarked
  or due earlier after its own window has passed).

Whether a candidate is alerted is decided by ``app.domain.missed.alert_due_at`` over the shared
dose-state fold. Invalid rules and zones are skipped and logged by schedule id and error code
only: a validation error would print the rule.
"""

from __future__ import annotations

import uuid
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta

from pydantic import ValidationError
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.alerts import MissedDoseAlert
from app.domain.dose_state import OccurrenceState, occurrence_states_by_key
from app.domain.missed import (
    DetectionWindow,
    alert_due_at,
    is_unconfirmed,
    occurrence_instant,
)
from app.domain.schedule import ScheduleRule, expand, load_zone
from app.observability import get_logger
from app.services.changes import lock_journal
from app.services.missed_queries import (
    ProfileInfo,
    ScheduleInfo,
    eligible_among,
    events_of_keys,
    last_seen_by_owner,
    load_grants,
    load_schedules,
    snoozed_keys,
    undone_keys,
)
from app.services.missed_recipients import AlertSubject, push_items
from app.services.push_outbox import enqueue_many

_log = get_logger("pillpal.detector")

Key = tuple[uuid.UUID, str]
_UNMARKED = OccurrenceState(mark=None, snooze_until=None)


@dataclass(frozen=True, slots=True)
class BatchResult:
    profiles: int = 0
    alerts: int = 0
    pushes: int = 0


@dataclass(frozen=True, slots=True)
class _Schedule:
    info: ScheduleInfo
    rule: ScheduleRule
    zone: str
    profile: ProfileInfo


@dataclass(frozen=True, slots=True)
class _Candidate:
    occurrence_at: datetime
    schedule: _Schedule
    late_undo: bool


@dataclass(frozen=True, slots=True)
class _Draft:
    alert_id: uuid.UUID
    profile: ProfileInfo
    schedule: _Schedule
    key: str
    occurrence_at: datetime
    due_at: datetime


def _parse_schedules(
    infos: Iterable[ScheduleInfo], profiles: dict[uuid.UUID, ProfileInfo]
) -> dict[uuid.UUID, _Schedule]:
    parsed: dict[uuid.UUID, _Schedule] = {}
    for info in infos:
        profile = profiles[info.profile_id]
        zone = info.fixed_tz if info.tz_mode == "fixed" and info.fixed_tz else profile.timezone
        try:
            rule = ScheduleRule.model_validate(info.rule)
        except ValidationError:
            _log.warning(
                "detector_invalid_rule", schedule_id=str(info.id), error_code="invalid_rule"
            )
            continue
        try:
            load_zone(zone)
        except ValueError:
            _log.warning(
                "detector_invalid_timezone", schedule_id=str(info.id), error_code="invalid_timezone"
            )
            continue
        parsed[info.id] = _Schedule(info, rule, zone, profile)
    return parsed


def _schedule_id_of(key: str) -> uuid.UUID | None:
    try:
        return uuid.UUID(key.split("/", 1)[0])
    except ValueError:
        return None


def _add(found: dict[Key, _Candidate], profile_id: uuid.UUID, key: str, new: _Candidate) -> None:
    old = found.get((profile_id, key))
    late = new.late_undo or (old is not None and old.late_undo)
    found[(profile_id, key)] = _Candidate(new.occurrence_at, new.schedule, late)


def _expanded(
    parsed: Iterable[_Schedule], window: DetectionWindow
) -> Iterable[tuple[Key, _Candidate]]:
    """Candidate A: ``instant + grace`` in the window <=> ``instant`` in the shifted window."""
    for schedule in parsed:
        grace = schedule.profile.grace
        for occurrence in expand(
            schedule.rule,
            schedule_id=str(schedule.info.id),
            tz=schedule.zone,
            start=window.start - grace,
            end=window.end - grace,
        ):
            yield (
                (schedule.profile.id, occurrence.key),
                _Candidate(occurrence.at_utc, schedule, late_undo=False),
            )


async def _candidates(
    session: AsyncSession, window: DetectionWindow, profiles: dict[uuid.UUID, ProfileInfo]
) -> dict[Key, _Candidate]:
    profile_ids = list(profiles)
    snoozed = await snoozed_keys(session, window, profile_ids)
    undone = await undone_keys(session, window, profile_ids)
    named = snoozed | undone
    named_schedules = {sid for _, key in named if (sid := _schedule_id_of(key)) is not None}
    infos = await load_schedules(session, window, profile_ids, named_schedules)
    parsed = _parse_schedules(infos, profiles)
    found: dict[Key, _Candidate] = {}
    for (profile_id, key), candidate in _expanded(parsed.values(), window):
        _add(found, profile_id, key, candidate)
    for profile_id, key in named:
        sid = _schedule_id_of(key)
        schedule = parsed.get(sid) if sid is not None else None
        if schedule is None or schedule.info.profile_id != profile_id:
            continue  # a deleted schedule, or a key naming another profile's schedule
        instant = occurrence_instant(schedule.rule, str(schedule.info.id), schedule.zone, key)
        if instant is not None:
            _add(found, profile_id, key, _Candidate(instant, schedule, (profile_id, key) in undone))
    # A schedule created after an occurrence was due never owed a dose for it.
    return {k: c for k, c in found.items() if c.occurrence_at >= c.schedule.info.created_at}


async def _decide(
    session: AsyncSession,
    settings: Settings,
    window: DetectionWindow,
    candidates: dict[Key, _Candidate],
) -> list[_Draft]:
    if not candidates:
        return []
    events = await events_of_keys(
        session, {profile_id for profile_id, _ in candidates}, {key for _, key in candidates}
    )
    states = occurrence_states_by_key(events)
    horizon = timedelta(seconds=settings.detector_max_catchup_seconds)
    drafts: list[_Draft] = []
    for (_, key), candidate in candidates.items():
        profile = candidate.schedule.profile
        due = alert_due_at(
            states.get(key, _UNMARKED),
            candidate.occurrence_at,
            profile.grace,
            window,
            late_undo=candidate.late_undo,
            horizon=horizon,
        )
        if due is not None:
            drafts.append(
                _Draft(uuid.uuid4(), profile, candidate.schedule, key, candidate.occurrence_at, due)
            )
    return drafts


async def _persist(session: AsyncSession, drafts: Sequence[_Draft], now: datetime) -> BatchResult:
    self_owners = {d.profile.owner_id for d in drafts if d.profile.kind == "self"}
    seen = await last_seen_by_owner(session, self_owners) if self_owners else {}
    unconfirmed = {
        d.alert_id: is_unconfirmed(
            d.profile.kind,
            [seen[d.profile.owner_id]] if d.profile.owner_id in seen else [],
            d.occurrence_at,
        )
        for d in drafts
    }
    inserted = await session.execute(
        pg_insert(MissedDoseAlert)
        .values(
            [
                {
                    "id": d.alert_id,
                    "profile_id": d.profile.id,
                    "medication_id": d.schedule.info.medication_id,
                    "occurrence_key": d.key,
                    "due_at": d.due_at,
                    "variant": "unconfirmed" if unconfirmed[d.alert_id] else "missed",
                    "detected_at": now,
                }
                for d in drafts
            ]
        )
        .on_conflict_do_nothing(index_elements=["profile_id", "occurrence_key"])
        .returning(MissedDoseAlert.id)
    )
    created = {row[0] for row in inserted}
    new = [d for d in drafts if d.alert_id in created]
    if not new:
        return BatchResult()
    grants = await load_grants(session, {d.profile.id for d in new})
    items = [
        item
        for d in new
        for item in push_items(
            "missed",
            AlertSubject(
                d.alert_id,
                d.profile.id,
                d.schedule.info.medication_id,
                d.due_at,
                d.profile.kind,
                d.profile.owner_id,
                d.schedule.info.privacy,
                unconfirmed[d.alert_id],
            ),
            grants.get(d.profile.id, []),
        )
    ]
    pushes = await enqueue_many(session, items, now=now)
    return BatchResult(alerts=len(new), pushes=pushes)


async def process_batch(
    session: AsyncSession,
    settings: Settings,
    window: DetectionWindow,
    page: Sequence[tuple[uuid.UUID, uuid.UUID]],
    now: datetime,
) -> BatchResult:
    """Alert what the window owes for the profiles of ``page`` (``(profile id, owner id)``).

    The caller commits. Eligibility is read again under the locks: a deletion request or an
    archive that committed while the page was being read is seen here.
    """
    await lock_journal(session, {owner_id for _, owner_id in page})
    eligible = await eligible_among(session, [profile_id for profile_id, _ in page])
    if not eligible:
        return BatchResult()
    profiles = {p.id: p for p in eligible}
    candidates = await _candidates(session, window, profiles)
    drafts = await _decide(session, settings, window, candidates)
    if not drafts:
        return BatchResult(profiles=len(profiles))
    result = await _persist(session, drafts, now)
    return BatchResult(len(profiles), result.alerts, result.pushes)
