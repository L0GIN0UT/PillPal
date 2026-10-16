"""Dose state of an occurrence, folded from its dose events (reference implementation).

Specification: ``docs/spec/dose-state.md``; executable contract:
``spec/dose-state-vectors/``. The Dart port in ``packages/pillpal_core`` runs the same
vectors. Pure: no IO, no clock (``now`` is always an argument).
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Literal

DoseEventType = Literal["taken", "skipped", "snoozed", "undo"]
MarkType = Literal["taken", "skipped"]

_MARK_TYPES: frozenset[str] = frozenset({"taken", "skipped"})


def _require_aware(value: datetime, name: str) -> None:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError(f"{name} must be timezone-aware")


@dataclass(frozen=True, slots=True)
class DoseEvent:
    """One dose event as the state fold sees it (docs/spec/dose-state.md section 1.2)."""

    id: str
    type: DoseEventType
    at: datetime
    occurrence_key: str | None = None
    target_event_id: str | None = None
    snooze_until: datetime | None = None

    def __post_init__(self) -> None:
        _require_aware(self.at, "at")
        if self.snooze_until is not None:
            _require_aware(self.snooze_until, "snooze_until")


@dataclass(frozen=True, slots=True)
class DoseMark:
    """The ``taken`` or ``skipped`` event in effect for an occurrence."""

    event_id: str
    type: MarkType
    at: datetime


@dataclass(frozen=True, slots=True)
class OccurrenceState:
    """What the events say about one occurrence: its mark and its latest snooze."""

    mark: DoseMark | None
    snooze_until: datetime | None

    def due_at(self, occurrence_at: datetime) -> datetime:
        """``max(occurrence instant, snooze_until)``: a snooze never moves due earlier."""
        _require_aware(occurrence_at, "occurrence_at")
        if self.snooze_until is None:
            return occurrence_at
        return max(occurrence_at, self.snooze_until)

    def is_missed(self, *, occurrence_at: datetime, now: datetime, grace: timedelta) -> bool:
        """Unmarked and ``now >= due + grace`` (inclusive, exact to the microsecond)."""
        _require_aware(now, "now")
        if grace < timedelta(0):
            raise ValueError("grace must not be negative")
        if self.mark is not None:
            return False
        return now >= self.due_at(occurrence_at) + grace


def cancelled_event_ids(events: Iterable[DoseEvent]) -> frozenset[str]:
    """Ids cancelled by the undos in ``events`` (spec section 2).

    Every undo counts, whatever its own key or instant; undos without a target add nothing.

    An undo is never itself cancelled, so an undo of an undo only adds that undo's id,
    which no mark or snooze carries.
    """
    return frozenset(
        event.target_event_id
        for event in events
        if event.type == "undo" and event.target_event_id is not None
    )


def _latest(events: Iterable[DoseEvent]) -> DoseEvent | None:
    """The event with the greatest ``at``; ties go to the greatest id (ADR 0003 section 6)."""
    return max(events, key=lambda event: (event.at, event.id), default=None)


def _fold(events: Iterable[DoseEvent], cancelled: frozenset[str]) -> OccurrenceState:
    live = [event for event in events if event.id not in cancelled]
    latest_mark = _latest(event for event in live if event.type in _MARK_TYPES)
    latest_snooze = _latest(
        event for event in live if event.type == "snoozed" and event.snooze_until is not None
    )
    mark: DoseMark | None = None
    if latest_mark is not None:
        mark_type: MarkType = "taken" if latest_mark.type == "taken" else "skipped"
        mark = DoseMark(event_id=latest_mark.id, type=mark_type, at=latest_mark.at)
    return OccurrenceState(
        mark=mark,
        snooze_until=None if latest_snooze is None else latest_snooze.snooze_until,
    )


def summarize_events(events: Iterable[DoseEvent]) -> OccurrenceState:
    """State of one occurrence from its events; ``occurrence_key`` is not consulted.

    The caller has grouped the events (undos included).
    """
    items = list(events)
    return _fold(items, cancelled_event_ids(items))


def occurrence_state(events: Iterable[DoseEvent], occurrence_key: str) -> OccurrenceState:
    """State of ``occurrence_key`` from mixed events; other keys are ignored.

    Undos of any key still cancel their target (spec section 2).
    """
    items = list(events)
    own = [event for event in items if event.occurrence_key == occurrence_key]
    return _fold(own, cancelled_event_ids(items))


def occurrence_states_by_key(events: Iterable[DoseEvent]) -> dict[str, OccurrenceState]:
    """State of every occurrence key in ``events`` that has a live mark or snooze."""
    items = list(events)
    cancelled = cancelled_event_ids(items)
    grouped: dict[str, list[DoseEvent]] = {}
    for event in items:
        if event.occurrence_key is not None:
            grouped.setdefault(event.occurrence_key, []).append(event)
    states = {key: _fold(group, cancelled) for key, group in grouped.items()}
    return {
        key: state
        for key, state in states.items()
        if state.mark is not None or state.snooze_until is not None
    }
