import 'dart:convert';

import 'package:pillpal_core/pillpal_core.dart';

import '../../data/db/database.dart';
import '../../data/repositories/dose_events_repository.dart';
import '../common/local_time.dart';
import 'dose_status.dart';

/// A schedule row with its parsed rule.
class ParsedSchedule {
  /// Creates a parsed schedule.
  const ParsedSchedule(this.row, this.rule);

  /// Stored row.
  final ScheduleRow row;

  /// Validated rule.
  final ScheduleRule rule;
}

/// Parses rules, skipping rows whose rule is invalid (never expected for
/// canonical rows; a bad row must not break the whole screen).
List<ParsedSchedule> parseSchedules(Iterable<ScheduleRow> rows) {
  final result = <ParsedSchedule>[];
  for (final row in rows) {
    try {
      result.add(
          ParsedSchedule(row, ScheduleRule.fromJson(jsonDecode(row.rule))));
    } on RuleValidationError {
      continue;
    } on FormatException {
      continue;
    }
  }
  return result;
}

/// The zone occurrences of [medication] are computed in
/// (docs/spec/schedule.md §3.1: `local` -> device zone, `fixed` -> its zone).
String effectiveZone(MedicationRow medication, String deviceTz) {
  final fixed = medication.fixedTz;
  if (medication.tzMode == 'fixed' && fixed != null && isKnownTimeZone(fixed)) {
    return fixed;
  }
  return deviceTz;
}

/// One occurrence of a medication with its current status.
class ScheduledDose {
  /// Creates a dose.
  const ScheduledDose({
    required this.medication,
    required this.scheduleId,
    required this.occurrence,
    required this.status,
    required this.mark,
    required this.zone,
  });

  /// The medication.
  final MedicationRow medication;

  /// Schedule that produced [occurrence].
  final String scheduleId;

  /// Engine occurrence (nominal key, instant, dose).
  final Occurrence occurrence;

  /// Status at the time of computation.
  final DoseStatus status;

  /// Effective taken/skipped event, if any.
  final DoseMark? mark;

  /// Effective zone of the medication.
  final String zone;

  /// Reference for recording events.
  OccurrenceRef get ref => OccurrenceRef.fromOccurrence(scheduleId, occurrence);

  /// Instant (UTC).
  DateTime get dueAt => occurrence.atUtc;

  /// Whether the dose can still be marked (pending or missed).
  bool get isOpen =>
      status == DoseStatus.pending || status == DoseStatus.missed;
}

/// All occurrences with instant in `[start, end)` of [schedules] belonging
/// to [medications], with statuses from [events], sorted by instant.
List<ScheduledDose> buildScheduledDoses({
  required Iterable<MedicationRow> medications,
  required Iterable<ParsedSchedule> schedules,
  required Iterable<DoseEventRow> events,
  required String deviceTz,
  required DateTime start,
  required DateTime end,
  required DateTime now,
}) {
  final byId = {for (final m in medications) m.id: m};
  final byKey = eventsByOccurrence(events);
  final result = <ScheduledDose>[];
  for (final schedule in schedules) {
    final medication = byId[schedule.row.medicationId];
    if (medication == null) {
      continue;
    }
    final zone = effectiveZone(medication, deviceTz);
    final occurrences = expand(
      schedule.rule,
      scheduleId: schedule.row.id,
      tz: zone,
      start: start,
      end: end,
    );
    for (final occurrence in occurrences) {
      final mark = effectiveMark(byKey[occurrence.key] ?? const []);
      result.add(
        ScheduledDose(
          medication: medication,
          scheduleId: schedule.row.id,
          occurrence: occurrence,
          status: doseStatus(mark, occurrence.atUtc, now),
          mark: mark,
          zone: zone,
        ),
      );
    }
  }
  result.sort((a, b) {
    final byInstant = a.dueAt.compareTo(b.dueAt);
    return byInstant != 0
        ? byInstant
        : a.occurrence.key.compareTo(b.occurrence.key);
  });
  return result;
}

/// `taken` events without an occurrence (as-needed doses), not undone.
List<DoseEventRow> asNeededIntakes(
  Iterable<DoseEventRow> events,
  String medicationId,
) {
  final undone = undoneEventIds(events);
  return [
    for (final event in events)
      if (event.medicationId == medicationId &&
          event.occurrenceKey == null &&
          event.eventType == DoseEventType.taken.wire &&
          !undone.contains(event.id))
        event,
  ];
}
