"""Pure rules of the missed-dose detector (ADR 0007): windows, final due, variant, recipients."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest

from app.domain.dose_state import DoseMark, OccurrenceState
from app.domain.missed import (
    DetectionWindow,
    GrantInfo,
    alert_due_at,
    include_medication_id,
    is_unconfirmed,
    next_window,
    occurrence_instant,
    recipients_of,
)
from app.domain.schedule import ScheduleRule

T0 = datetime(2026, 10, 17, 8, 0, tzinfo=UTC)
MAX_WINDOW = timedelta(minutes=10)
MAX_CATCHUP = timedelta(hours=6)
GRACE = timedelta(minutes=30)
SCHEDULE = "11111111-1111-4111-8111-111111111111"


def _rule(**overrides: object) -> ScheduleRule:
    doc: dict[str, object] = {
        "v": 1,
        "kind": "daily",
        "start_date": "2026-10-01",
        "end_date": None,
        "times": [{"time": "08:00", "dose": {"amount": "1", "unit": "tablet"}}],
    }
    doc.update(overrides)
    return ScheduleRule.model_validate(doc)


# --- windows -------------------------------------------------------------------------------


def test_window_is_capped_at_the_max_window() -> None:
    window = next_window(
        T0, T0 + timedelta(hours=1), max_window=MAX_WINDOW, max_catchup=MAX_CATCHUP
    )
    assert window == DetectionWindow(T0, T0 + MAX_WINDOW, skipped=timedelta(0))


def test_window_ends_at_now_when_caught_up() -> None:
    now = T0 + timedelta(seconds=60)
    window = next_window(T0, now, max_window=MAX_WINDOW, max_catchup=MAX_CATCHUP)
    assert window == DetectionWindow(T0, now, skipped=timedelta(0))


def test_no_window_when_the_watermark_is_not_behind_now() -> None:
    assert next_window(T0, T0, max_window=MAX_WINDOW, max_catchup=MAX_CATCHUP) is None
    assert (
        next_window(T0, T0 - timedelta(seconds=1), max_window=MAX_WINDOW, max_catchup=MAX_CATCHUP)
        is None
    )


def test_downtime_longer_than_the_catchup_jumps_the_start() -> None:
    now = T0 + timedelta(hours=9)
    window = next_window(T0, now, max_window=MAX_WINDOW, max_catchup=MAX_CATCHUP)
    assert window is not None
    assert window.start == now - MAX_CATCHUP
    assert window.skipped == timedelta(hours=3)
    assert window.end == window.start + MAX_WINDOW


def test_downtime_of_exactly_the_catchup_skips_nothing() -> None:
    window = next_window(T0, T0 + MAX_CATCHUP, max_window=MAX_WINDOW, max_catchup=MAX_CATCHUP)
    assert window is not None
    assert window.start == T0
    assert window.skipped == timedelta(0)


# --- final due -----------------------------------------------------------------------------

UNMARKED = OccurrenceState(mark=None, snooze_until=None)
MARKED = OccurrenceState(mark=DoseMark("e", "taken", T0), snooze_until=None)


def _window(start: datetime) -> DetectionWindow:
    return DetectionWindow(start, start + MAX_WINDOW, skipped=timedelta(0))


def test_alert_when_due_plus_grace_is_inside_the_window() -> None:
    window = _window(T0 + GRACE)
    assert alert_due_at(UNMARKED, T0, GRACE, window, late_undo=False, horizon=MAX_CATCHUP) == T0


def test_window_end_is_exclusive_and_start_inclusive() -> None:
    at_start = _window(T0 + GRACE)
    assert alert_due_at(UNMARKED, T0, GRACE, at_start, late_undo=False, horizon=MAX_CATCHUP)
    at_end = _window(T0 + GRACE - MAX_WINDOW)
    assert alert_due_at(UNMARKED, T0, GRACE, at_end, late_undo=False, horizon=MAX_CATCHUP) is None


def test_marked_occurrences_never_alert() -> None:
    window = _window(T0 + GRACE)
    assert alert_due_at(MARKED, T0, GRACE, window, late_undo=True, horizon=MAX_CATCHUP) is None


def test_snooze_moves_the_final_due() -> None:
    state = OccurrenceState(mark=None, snooze_until=T0 + timedelta(minutes=20))
    old_window = _window(T0 + GRACE)  # the original due + grace
    assert alert_due_at(state, T0, GRACE, old_window, late_undo=False, horizon=MAX_CATCHUP) is None
    new_window = _window(T0 + timedelta(minutes=20) + GRACE)
    assert alert_due_at(
        state, T0, GRACE, new_window, late_undo=False, horizon=MAX_CATCHUP
    ) == T0 + timedelta(minutes=20)


def test_late_undo_alerts_after_the_window_has_passed() -> None:
    window = _window(T0 + GRACE + timedelta(hours=1))
    assert alert_due_at(UNMARKED, T0, GRACE, window, late_undo=False, horizon=MAX_CATCHUP) is None
    assert alert_due_at(UNMARKED, T0, GRACE, window, late_undo=True, horizon=MAX_CATCHUP) == T0


def test_late_undo_does_not_alert_before_due_plus_grace() -> None:
    window = _window(T0)
    assert alert_due_at(UNMARKED, T0, GRACE, window, late_undo=True, horizon=MAX_CATCHUP) is None


def test_late_undo_of_an_old_occurrence_is_not_alerted() -> None:
    # Undoing yesterday's mark in the history must not page relatives about yesterday.
    window = _window(T0 + timedelta(days=1))
    assert alert_due_at(UNMARKED, T0, GRACE, window, late_undo=True, horizon=MAX_CATCHUP) is None


# --- occurrence instants of keys -----------------------------------------------------------


def test_occurrence_instant_of_a_real_key() -> None:
    key = f"{SCHEDULE}/2026-10-17T08:00"
    assert occurrence_instant(_rule(), SCHEDULE, "Europe/Samara", key) == datetime(
        2026, 10, 17, 4, 0, tzinfo=UTC
    )


def test_occurrence_instant_in_a_dst_gap_uses_the_pre_transition_offset() -> None:
    rule = _rule(
        start_date="2026-03-01",
        times=[{"time": "02:30", "dose": {"amount": "1", "unit": "tablet"}}],
    )
    key = f"{SCHEDULE}/2026-03-29T02:30"
    assert occurrence_instant(rule, SCHEDULE, "Europe/Berlin", key) == datetime(
        2026, 3, 29, 1, 30, tzinfo=UTC
    )


@pytest.mark.parametrize(
    "key",
    [
        f"{SCHEDULE}/2026-10-17T09:00",  # no such slot
        f"{SCHEDULE}/2026-09-30T08:00",  # before the course
        f"{SCHEDULE}/2026-13-01T08:00",  # not a date
        f"{SCHEDULE}/2026-10-17T8:00",  # not HH:MM
        "22222222-2222-4222-8222-222222222222/2026-10-17T08:00",  # another schedule
        "garbage",
        "",
    ],
)
def test_keys_that_are_not_occurrences_have_no_instant(key: str) -> None:
    assert occurrence_instant(_rule(), SCHEDULE, "UTC", key) is None


def test_weekday_rule_rejects_a_key_on_another_weekday() -> None:
    rule = _rule(kind="weekdays", weekdays=[1])  # Mondays; 2026-10-17 is a Saturday
    assert occurrence_instant(rule, SCHEDULE, "UTC", f"{SCHEDULE}/2026-10-17T08:00") is None
    assert occurrence_instant(rule, SCHEDULE, "UTC", f"{SCHEDULE}/2026-10-19T08:00") is not None


# --- variant -------------------------------------------------------------------------------


def test_unconfirmed_needs_a_self_profile_and_every_device_last_seen_before_the_instant() -> None:
    before = [T0 - timedelta(hours=2), T0 - timedelta(minutes=1)]
    assert is_unconfirmed("self", before, T0)
    assert not is_unconfirmed("managed", before, T0)
    assert not is_unconfirmed("self", [*before, T0], T0)  # seen exactly at the instant
    assert not is_unconfirmed("self", [*before, T0 + timedelta(minutes=5)], T0)


def test_a_self_profile_without_devices_is_unconfirmed() -> None:
    assert is_unconfirmed("self", [], T0)


# --- recipients ----------------------------------------------------------------------------

OWNER = uuid.uuid4()
GUARDIAN, VIEWER, EDITOR = (uuid.uuid4() for _ in range(3))
EARLY = T0 - timedelta(days=1)


def _grant(user: uuid.UUID, role: str, **overrides: object) -> GrantInfo:
    values: dict[str, object] = {
        "user_id": user,
        "role": role,
        "created_at": EARLY,
        "notify_missed": True,
    }
    values.update(overrides)
    return GrantInfo(**values)  # type: ignore[arg-type]


def _ids(recipients: list) -> set[uuid.UUID]:  # type: ignore[type-arg]
    return {r.user_id for r in recipients}


def test_self_owner_is_never_a_recipient() -> None:
    result = recipients_of("self", OWNER, [_grant(VIEWER, "viewer")], T0, "shared")
    assert _ids(result) == {VIEWER}


def test_managed_owner_is_alerted_only_with_co_guardians() -> None:
    assert recipients_of("managed", OWNER, [], T0, "shared") == []
    assert (
        recipients_of("managed", OWNER, [_grant(VIEWER, "viewer")], T0, "shared")[0].user_id
        == VIEWER
    )
    both = recipients_of("managed", OWNER, [_grant(GUARDIAN, "guardian")], T0, "shared")
    assert _ids(both) == {OWNER, GUARDIAN}


def test_a_muted_guardian_still_counts_as_co_guardian_for_the_owner() -> None:
    result = recipients_of(
        "managed", OWNER, [_grant(GUARDIAN, "guardian", notify_missed=False)], T0, "shared"
    )
    assert _ids(result) == {OWNER}


def test_grantees_who_muted_are_excluded() -> None:
    result = recipients_of(
        "self", OWNER, [_grant(VIEWER, "viewer", notify_missed=False)], T0, "shared"
    )
    assert result == []


def test_grants_created_after_the_due_time_are_excluded() -> None:
    late = _grant(VIEWER, "viewer", created_at=T0 + timedelta(seconds=1))
    exact = _grant(EDITOR, "editor", created_at=T0)
    assert _ids(recipients_of("self", OWNER, [late, exact], T0, "shared")) == {EDITOR}


def test_hidden_medications_go_to_full_access_recipients_only() -> None:
    grants = [_grant(GUARDIAN, "guardian"), _grant(VIEWER, "viewer"), _grant(EDITOR, "editor")]
    result = recipients_of("managed", OWNER, grants, T0, "hidden")
    assert _ids(result) == {OWNER, GUARDIAN}
    assert all(r.full_access for r in result)


def test_anonymous_goes_to_everyone_but_only_full_access_gets_the_medication_id() -> None:
    result = recipients_of(
        "managed", OWNER, [_grant(GUARDIAN, "guardian"), _grant(VIEWER, "viewer")], T0, "anonymous"
    )
    assert _ids(result) == {OWNER, GUARDIAN, VIEWER}
    with_id = {r.user_id for r in result if include_medication_id("anonymous", r)}
    assert with_id == {OWNER, GUARDIAN}


def test_shared_medication_id_goes_to_every_recipient() -> None:
    result = recipients_of("self", OWNER, [_grant(VIEWER, "viewer")], T0, "shared")
    assert all(include_medication_id("shared", r) for r in result)
