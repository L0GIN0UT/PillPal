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

  /// Not marked and at least [DoseTiming.missedGrace] past its due time
  /// (its time, or the end of its snooze).
  missed,
}

/// The latest `taken`/`skipped` event by `at` not cancelled by an `undo`
/// (ADR 0003 §6; ties: the larger id, the same on every device).
///
/// Dose events are append-only (TZ §2.4): a correction is an `undo` of the
/// earlier event, so the effective mark is recomputed from the whole set.
/// The rule is the shared dose-state contract (docs/spec/dose-state.md),
/// implemented in `pillpal_core`.
DoseMark? effectiveMark(Iterable<DoseEventRow> events) =>
    summarizeEvents(doseEventsOf(events)).mark;

/// Status of an occurrence due at [occurrenceAt] whose events fold to
/// [state], at [now].
///
/// `missed` is the contract's `missed(now, grace)` with
/// [DoseTiming.missedGrace] (docs/spec/dose-state.md §5): a snoozed dose is
/// not missed until its `snooze_until` plus the grace.
DoseStatus doseStatus(
  OccurrenceState state,
  DateTime occurrenceAt,
  DateTime now,
) {
  final mark = state.mark;
  if (mark != null) {
    return mark.type == DoseEventType.taken
        ? DoseStatus.taken
        : DoseStatus.skipped;
  }
  final missed = state.isMissed(
    occurrenceAt: occurrenceAt,
    now: now,
    grace: DoseTiming.missedGrace,
  );
  return missed ? DoseStatus.missed : DoseStatus.pending;
}
