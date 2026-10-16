import 'dart:convert';

import 'package:pillpal_core/pillpal_core.dart';

import '../doses/scheduled_doses.dart';

/// How saving an edited rule changes the stored schedules (ADR 0003).
sealed class ScheduleEditPlan {
  const ScheduleEditPlan();
}

/// The rule did not change: nothing is written.
class KeepSchedule extends ScheduleEditPlan {
  /// Creates the plan.
  const KeepSchedule();
}

/// Replace the rule of the schedule: no past day depends on it.
class EditInPlace extends ScheduleEditPlan {
  /// Creates the plan.
  const EditInPlace(this.rule);

  /// The new rule document.
  final Map<String, Object?> rule;
}

/// End the schedule on [endDate] and continue with [rule] as a new schedule
/// of the same medication, so past occurrences keep their keys and marks.
class SplitSchedule extends ScheduleEditPlan {
  /// Creates the plan.
  const SplitSchedule({required this.endDate, required this.rule});

  /// Last day of the old schedule (yesterday).
  final LocalDate endDate;

  /// The rule of the new schedule, starting today or later.
  final Map<String, Object?> rule;
}

/// Why an edit cannot be saved.
enum ScheduleEditError {
  /// The schedule has ended; a new schedule resumes the medication.
  ended,

  /// A started schedule may not end before today (that is "finish").
  endsBeforeToday,
}

/// An edit [planScheduleEdit] refuses.
class ScheduleEditException implements Exception {
  /// Creates the exception.
  const ScheduleEditException(this.error);

  /// The reason.
  final ScheduleEditError error;

  @override
  String toString() => 'ScheduleEditException(${error.name})';
}

/// What saving [edited] over [current] does on [today], the date in the
/// medication's effective zone (ADR 0003 §1, §2).
///
/// Throws [ScheduleEditException] for an ended schedule or an edit that
/// would end a started schedule before today.
ScheduleEditPlan planScheduleEdit({
  required ScheduleRule current,
  required ScheduleRule edited,
  required LocalDate today,
}) {
  if (hasEndedBy(current, today)) {
    throw const ScheduleEditException(ScheduleEditError.ended);
  }
  final rule = edited.toJson();
  if (_canonical(current.toJson()) == _canonical(rule)) {
    return const KeepSchedule();
  }
  if (!hasHistoryBefore(current, today)) {
    return EditInPlace(rule);
  }
  final end = edited.endDate;
  if (end != null && end.isBefore(today)) {
    throw const ScheduleEditException(ScheduleEditError.endsBeforeToday);
  }
  // Moving the course end only changes days from today on.
  if (_canonical({...current.toJson(), 'end_date': rule['end_date']}) ==
      _canonical(rule)) {
    return EditInPlace(rule);
  }
  final start = continuationStart(edited, today);
  if (end != null && end.isBefore(start)) {
    throw const ScheduleEditException(ScheduleEditError.endsBeforeToday);
  }
  return SplitSchedule(
    endDate: today.addDays(-1),
    rule: {...rule, 'start_date': start.toString()},
  );
}

/// First day of the schedule continuing [rule] from [today]: its own start
/// if that is not in the past, else today, or for `interval_days` the first
/// day on or after today in the rule's phase.
LocalDate continuationStart(ScheduleRule rule, LocalDate today) {
  final start = rule.startDate;
  if (!start.isBefore(today)) {
    return start;
  }
  final interval = rule.intervalDays;
  if (rule.kind != RuleKind.intervalDays || interval == null) {
    return today;
  }
  final behind = (today.epochDay - start.epochDay) % interval;
  return behind == 0 ? today : today.addDays(interval - behind);
}

String _canonical(Map<String, Object?> rule) => jsonEncode(rule);
