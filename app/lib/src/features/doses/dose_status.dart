import '../../data/db/database.dart';
import '../../data/repositories/dose_events_repository.dart';

/// UI timing constants (TZ §2.5: relatives are told after 30 minutes by
/// default; the app shows the dose as missed from the same moment).
abstract final class DoseTiming {
  /// A pending dose turns "missed" this long after its time.
  static const Duration missedGrace = Duration(minutes: 30);

  /// Delay of "remind me later" (senior mode button).
  static const Duration snooze = Duration(minutes: 15);

  /// Low-stock warning threshold when the medication has none.
  static const int defaultLowStockDays = 7;

  /// How often time-dependent screens refresh.
  static const Duration refreshEvery = Duration(minutes: 1);

  /// How long senior mode confirms a mark (with undo) before moving on.
  static const Duration confirmation = Duration(seconds: 3);
}

/// Status of one scheduled occurrence.
enum DoseStatus {
  /// Not marked and not overdue yet.
  pending,

  /// Marked as taken.
  taken,

  /// Deliberately skipped.
  skipped,

  /// Not marked and overdue by more than [DoseTiming.missedGrace].
  missed,
}

/// The `taken` or `skipped` event currently in effect for an occurrence.
class DoseMark {
  /// Creates a mark.
  const DoseMark({required this.eventId, required this.type, required this.at});

  /// The event (target of an undo).
  final String eventId;

  /// [DoseEventType.taken] or [DoseEventType.skipped].
  final DoseEventType type;

  /// When it was recorded (UTC).
  final DateTime at;
}

/// Groups events by occurrence key (events without a key are dropped).
Map<String, List<DoseEventRow>> eventsByOccurrence(
  Iterable<DoseEventRow> events,
) {
  final result = <String, List<DoseEventRow>>{};
  for (final event in events) {
    final key = event.occurrenceKey;
    if (key != null) {
      (result[key] ??= <DoseEventRow>[]).add(event);
    }
  }
  return result;
}

/// Ids of events cancelled by an `undo` in [events].
Set<String> undoneEventIds(Iterable<DoseEventRow> events) => {
      for (final event in events)
        if (event.eventType == DoseEventType.undo.wire &&
            event.targetEventId != null)
          event.targetEventId!,
    };

/// The latest `taken`/`skipped` event by `at` not cancelled by an `undo`
/// (ADR 0003 §6; ties: the larger id, the same on every device).
///
/// Dose events are append-only (TZ §2.4): a correction is an `undo` of the
/// earlier event, so the effective mark is recomputed from the whole set.
DoseMark? effectiveMark(Iterable<DoseEventRow> events) {
  final undone = undoneEventIds(events);
  DoseEventRow? latest;
  for (final event in events) {
    final type = event.eventType;
    if (type != DoseEventType.taken.wire &&
        type != DoseEventType.skipped.wire) {
      continue;
    }
    if (undone.contains(event.id)) {
      continue;
    }
    if (latest == null ||
        event.at > latest.at ||
        (event.at == latest.at && event.id.compareTo(latest.id) > 0)) {
      latest = event;
    }
  }
  if (latest == null) {
    return null;
  }
  return DoseMark(
    eventId: latest.id,
    type: latest.eventType == DoseEventType.taken.wire
        ? DoseEventType.taken
        : DoseEventType.skipped,
    at: DateTime.fromMicrosecondsSinceEpoch(latest.at, isUtc: true),
  );
}

/// Status of an occurrence due at [dueAt] given its [mark], at [now].
DoseStatus doseStatus(DoseMark? mark, DateTime dueAt, DateTime now) {
  if (mark != null) {
    return mark.type == DoseEventType.taken
        ? DoseStatus.taken
        : DoseStatus.skipped;
  }
  return now.isAfter(dueAt.add(DoseTiming.missedGrace))
      ? DoseStatus.missed
      : DoseStatus.pending;
}
