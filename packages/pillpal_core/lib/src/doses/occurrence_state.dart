import 'dose_event.dart';
import 'moment.dart';

/// The `taken` or `skipped` event in effect for an occurrence.
class DoseMark {
  /// Creates a mark.
  const DoseMark({required this.eventId, required this.type, required this.at});

  /// The event (the target of an undo).
  final String eventId;

  /// [DoseEventType.taken] or [DoseEventType.skipped].
  final DoseEventType type;

  /// When it was recorded.
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is DoseMark &&
      other.eventId == eventId &&
      other.type == type &&
      sameMoment(other.at, at);

  @override
  int get hashCode => Object.hash(eventId, type, momentHash(at));
}

/// What the dose events say about one occurrence
/// (`docs/spec/dose-state.md`): its mark and its latest snooze.
class OccurrenceState {
  /// Creates a state.
  const OccurrenceState({this.mark, this.snoozeUntil});

  /// The last non-undone `taken`/`skipped` event (ties: the larger id), or
  /// null when the occurrence is unmarked (ADR 0003 §6).
  final DoseMark? mark;

  /// `snoozeUntil` of the latest non-undone snooze, or null.
  final DateTime? snoozeUntil;

  /// `max(occurrence instant, snoozeUntil)`: a snooze never moves the due
  /// instant earlier.
  DateTime dueAt(DateTime occurrenceAt) {
    final until = snoozeUntil;
    return until != null && until.isAfter(occurrenceAt) ? until : occurrenceAt;
  }

  /// Whether the occurrence is unmarked and `now >= dueAt + grace`
  /// (inclusive, exact to the microsecond).
  ///
  /// Throws [ArgumentError] for a negative [grace].
  bool isMissed({
    required DateTime occurrenceAt,
    required DateTime now,
    required Duration grace,
  }) {
    if (grace.isNegative) {
      throw ArgumentError.value(grace, 'grace', 'Must not be negative');
    }
    if (mark != null) {
      return false;
    }
    return !now.isBefore(dueAt(occurrenceAt).add(grace));
  }

  @override
  bool operator ==(Object other) =>
      other is OccurrenceState &&
      other.mark == mark &&
      sameMoment(other.snoozeUntil, snoozeUntil);

  @override
  int get hashCode => Object.hash(mark, momentHash(snoozeUntil));
}

/// State of one occurrence from its events; `occurrenceKey` is not
/// consulted (the caller has grouped the events, undos included).
OccurrenceState summarizeEvents(Iterable<DoseEvent> events) {
  final all = events.toList();
  return _fold(all, cancelledEventIds(all));
}

/// State of [occurrenceKey] from mixed events; other keys are ignored.
/// Undos of any key still cancel their target (spec §2).
OccurrenceState occurrenceStateOf(
  Iterable<DoseEvent> events,
  String occurrenceKey,
) {
  final all = events.toList();
  final own = all.where((event) => event.occurrenceKey == occurrenceKey);
  return _fold(own, cancelledEventIds(all));
}

/// State of every occurrence key in [allEvents] that has a live mark or a
/// live snooze.
Map<String, OccurrenceState> occurrenceStatesByKey(
  Iterable<DoseEvent> allEvents,
) {
  final all = allEvents.toList();
  final cancelled = cancelledEventIds(all);
  final grouped = <String, List<DoseEvent>>{};
  for (final event in all) {
    final key = event.occurrenceKey;
    if (key != null) {
      (grouped[key] ??= <DoseEvent>[]).add(event);
    }
  }
  final states = <String, OccurrenceState>{};
  for (final entry in grouped.entries) {
    final state = _fold(entry.value, cancelled);
    if (state.mark != null || state.snoozeUntil != null) {
      states[entry.key] = state;
    }
  }
  return states;
}

/// Ids cancelled by the undos in [events] (spec §2): the target of every
/// undo, whatever the undo's own key or instant; undos without a target add
/// nothing. An undo is never itself cancelled, so an undo of an undo only
/// adds an id that no mark or snooze carries.
Set<String> cancelledEventIds(Iterable<DoseEvent> events) {
  final cancelled = <String>{};
  for (final event in events) {
    final target = event.targetEventId;
    if (event.type == DoseEventType.undo && target != null) {
      cancelled.add(target);
    }
  }
  return cancelled;
}

/// Whether [a] is later than [b]: greater `at`, ties the greater id.
bool _isLater(DoseEvent a, DoseEvent b) {
  final byTime = a.at.compareTo(b.at);
  return byTime != 0 ? byTime > 0 : a.id.compareTo(b.id) > 0;
}

OccurrenceState _fold(Iterable<DoseEvent> events, Set<String> cancelled) {
  DoseEvent? mark;
  DoseEvent? snooze;
  for (final event in events) {
    if (cancelled.contains(event.id)) {
      continue;
    }
    final type = event.type;
    if (type == DoseEventType.taken || type == DoseEventType.skipped) {
      if (mark == null || _isLater(event, mark)) {
        mark = event;
      }
    } else if (type == DoseEventType.snoozed && event.snoozeUntil != null) {
      if (snooze == null || _isLater(event, snooze)) {
        snooze = event;
      }
    }
  }
  return OccurrenceState(
    mark: _markOf(mark),
    snoozeUntil: snooze?.snoozeUntil,
  );
}

DoseMark? _markOf(DoseEvent? event) {
  if (event == null) {
    return null;
  }
  return DoseMark(eventId: event.id, type: event.type, at: event.at);
}
