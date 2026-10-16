"""Unit tests of the dose-state reference beyond the shared vectors."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta, timezone

import pytest

from app.domain.dose_state import (
    DoseEvent,
    OccurrenceState,
    occurrence_state,
    occurrence_states_by_key,
    summarize_events,
)

KEY = "sched-t01/2026-10-17T08:00"
OTHER_KEY = "sched-t01/2026-10-18T08:00"
OCCURRENCE_AT = datetime(2026, 10, 17, 4, 0, tzinfo=UTC)
GRACE = timedelta(minutes=30)


def _at(minute: int) -> datetime:
    return datetime(2026, 10, 17, 4, minute, tzinfo=UTC)


def test_naive_event_instants_are_rejected() -> None:
    with pytest.raises(ValueError, match="timezone-aware"):
        DoseEvent(id="evt-a", type="taken", at=datetime(2026, 10, 17, 4, 0))
    with pytest.raises(ValueError, match="timezone-aware"):
        DoseEvent(
            id="evt-a",
            type="snoozed",
            at=_at(0),
            snooze_until=datetime(2026, 10, 17, 4, 5),
        )


def test_snoozed_event_without_snooze_until_is_ignored() -> None:
    older = DoseEvent("evt-s1", "snoozed", _at(1), KEY, snooze_until=_at(10))
    broken = DoseEvent("evt-s2", "snoozed", _at(2), KEY)
    state = occurrence_state([older, broken], KEY)
    assert state.snooze_until == _at(10)


def test_undo_without_target_cancels_nothing() -> None:
    taken = DoseEvent("evt-a", "taken", _at(1), KEY)
    undo = DoseEvent("evt-b", "undo", _at(2), KEY)
    assert occurrence_state([taken, undo], KEY).mark is not None


def test_instants_are_compared_across_utc_offsets() -> None:
    plus_five = timezone(timedelta(hours=5))
    # 09:03 +05:00 is 04:03 UTC, later than 04:02 UTC although the wall clock reads later.
    later = DoseEvent("evt-a", "taken", datetime(2026, 10, 17, 9, 3, tzinfo=plus_five), KEY)
    earlier = DoseEvent("evt-b", "skipped", _at(2), KEY)
    state = summarize_events([earlier, later])
    assert state.mark is not None
    assert state.mark.event_id == "evt-a"
    assert (
        state.is_missed(
            occurrence_at=OCCURRENCE_AT.astimezone(plus_five),
            now=_at(30).astimezone(plus_five),
            grace=GRACE,
        )
        is False
    )


def test_missed_requires_aware_instants() -> None:
    state = OccurrenceState(mark=None, snooze_until=None)
    with pytest.raises(ValueError, match="timezone-aware"):
        state.is_missed(
            occurrence_at=datetime(2026, 10, 17, 4, 0),
            now=_at(30),
            grace=GRACE,
        )
    with pytest.raises(ValueError, match="timezone-aware"):
        state.due_at(datetime(2026, 10, 17, 4, 0))


def test_negative_grace_is_rejected() -> None:
    state = OccurrenceState(mark=None, snooze_until=None)
    with pytest.raises(ValueError, match="grace"):
        state.is_missed(occurrence_at=OCCURRENCE_AT, now=_at(30), grace=timedelta(minutes=-1))


def test_states_by_key_has_entries_only_for_marked_or_snoozed_keys() -> None:
    events = [
        DoseEvent("evt-a", "taken", _at(1), KEY),
        DoseEvent("evt-b", "snoozed", _at(2), OTHER_KEY, snooze_until=_at(20)),
        DoseEvent("evt-c", "taken", _at(3), "sched-t01/2026-10-19T08:00"),
        DoseEvent("evt-d", "undo", _at(4), "sched-t01/2026-10-19T08:00", target_event_id="evt-c"),
        DoseEvent("evt-e", "taken", _at(5), None),
    ]
    states = occurrence_states_by_key(events)
    assert set(states) == {KEY, OTHER_KEY}
    assert states[KEY].mark is not None
    assert states[KEY].snooze_until is None
    assert states[OTHER_KEY].mark is None
    assert states[OTHER_KEY].snooze_until == _at(20)


def test_states_by_key_applies_an_undo_without_key_to_its_target() -> None:
    events = [
        DoseEvent("evt-a", "taken", _at(1), KEY),
        DoseEvent("evt-b", "undo", _at(2), None, target_event_id="evt-a"),
    ]
    assert occurrence_states_by_key(events) == {}


def test_state_is_a_value() -> None:
    first = occurrence_state([DoseEvent("evt-a", "taken", _at(1), KEY)], KEY)
    second = summarize_events([DoseEvent("evt-a", "taken", _at(1), KEY)])
    assert first == second
    assert hash(first) == hash(second)
