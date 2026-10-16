import 'package:pillpal_core/pillpal_core.dart';

import '../../data/db/database.dart';
import '../../data/repositories/dose_event_mapping.dart';
import '../../reminders/reminder_settings.dart';

/// UI timing constants (TZ §2.5: relatives are told after 30 minutes by
/// default; the app shows the dose as missed from the same moment).
abstract final class DoseTiming {
  /// A pending dose turns "missed" this long after its time.
  static const Duration missedGrace = Duration(minutes: 30);

  /// Delay of "remind me later" (senior mode button), the same as the
  /// notification action's.
  static const Duration snooze = notificationSnooze;

  /// Low-stock warning threshold when the medication has none.
  static const int defaultLowStockDays = 7;

  /// How often time-dependent screens refresh.
  static const Duration refreshEvery = Duration(minutes: 1);

  /// How long senior mode confirms a mark (with undo) before moving on.
  static const Duration confirmation = Duration(seconds: 3);

  /// Taps on the confirmation's undo are ignored this long after it
  /// appears: a double tap on "take" must not undo the mark it just made.
  static const Duration undoGuard = Duration(milliseconds: 500);
}

/// Status of one scheduled occurrence.
enum DoseStatus {
  /// Not marked and not overdue yet.
  pending,

  /// Marked as taken.
  taken,

  /// Deliberately skipped.
  skipped,

  /// Not marked and at least [DoseTiming.missedGrace] past its time.
  missed,
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
/// The rule is the shared dose-state contract (docs/spec/dose-state.md),
/// implemented in `pillpal_core`.
DoseMark? effectiveMark(Iterable<DoseEventRow> events) =>
    summarizeEvents(doseEventsOf(events)).mark;

/// Status of an occurrence due at [dueAt] given its [mark], at [now].
///
/// `missed` is the contract's `missed(now, grace)` with
/// [DoseTiming.missedGrace]. [dueAt] is the occurrence instant: the screens
/// do not apply a snooze to it yet (the contract's `due` would).
DoseStatus doseStatus(DoseMark? mark, DateTime dueAt, DateTime now) {
  if (mark != null) {
    return mark.type == DoseEventType.taken
        ? DoseStatus.taken
        : DoseStatus.skipped;
  }
  final missed = const OccurrenceState().isMissed(
    occurrenceAt: dueAt,
    now: now,
    grace: DoseTiming.missedGrace,
  );
  return missed ? DoseStatus.missed : DoseStatus.pending;
}
