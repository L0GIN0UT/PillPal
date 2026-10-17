import 'package:pillpal_core/pillpal_core.dart';

import '../../data/db/database.dart';
import '../../data/repositories/dose_event_mapping.dart';
import '../../data/repositories/dose_events_repository.dart';
import '../../data/repositories/schedule_rows.dart';
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
      result.add(ParsedSchedule(row, parseScheduleRow(row)));
    } on RuleValidationError {
      continue;
    } on FormatException {
      continue;
    }
  }
  return result;
}

/// Whether [rule] has started by [day] and not ended before it.
bool isRunningOn(ScheduleRule rule, LocalDate day) {
  final end = rule.endDate;
  return !rule.startDate.isAfter(day) && (end == null || !end.isBefore(day));
}

/// Whether [rule] ended before [day] (ADR 0003 §2).
bool hasEndedBy(ScheduleRule rule, LocalDate day) {
  final end = rule.endDate;
  return end != null && end.isBefore(day);
}

/// Whether [rule] has produced days before [day], i.e. has history
/// (ADR 0003 §1, §3).
bool hasHistoryBefore(ScheduleRule rule, LocalDate day) =>
    rule.startDate.isBefore(day);

/// Whether a medication with schedule [rules] is archived on [day]: it has
/// schedules and all of them have ended (ADR 0003 §3).
bool isArchivedOn(Iterable<ScheduleRule> rules, LocalDate day) =>
    rules.isNotEmpty && rules.every((rule) => hasEndedBy(rule, day));

/// The zone occurrences of [medication] are computed in
/// (docs/spec/schedule.md §3.1: `local` -> [deviceTz], `fixed` -> its zone).
///
/// [deviceTz] is the zone `local` medications follow: the device zone for the
/// user's own profile, the profile's zone for any other (D4, the rule of the
/// reminder planner, `ProfileAccess.localZone`).
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
    required this.displayZone,
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

  /// The zone times are shown in: the device zone for the user's own
  /// profile, the profile's zone for another person's (grandma's 08:00 stays
  /// 08:00, D4).
  final String displayZone;

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
  final states = occurrenceStatesByKey(doseEventsOf(events));
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
      final state = states[occurrence.key] ?? const OccurrenceState();
      result.add(
        ScheduledDose(
          medication: medication,
          scheduleId: schedule.row.id,
          occurrence: occurrence,
          status: doseStatus(state, occurrence.atUtc, now),
          mark: state.mark,
          zone: zone,
          displayZone: deviceTz,
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
  final undone = cancelledEventIds(doseEventsOf(events));
  return [
    for (final event in events)
      if (event.medicationId == medicationId &&
          event.occurrenceKey == null &&
          event.eventType == DoseEventType.taken.wire &&
          !undone.contains(event.id))
        event,
  ];
}
