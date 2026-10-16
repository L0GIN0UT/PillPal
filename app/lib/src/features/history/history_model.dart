import 'package:pillpal_core/pillpal_core.dart';

import '../../data/db/database.dart';
import '../common/local_time.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';

/// Colour class of a calendar day (mockup "History").
enum DayAdherence {
  /// Nothing scheduled.
  empty,

  /// Every scheduled dose taken.
  allTaken,

  /// Some taken, some not.
  partial,

  /// None taken.
  missed,

  /// Today (outlined, day not over yet).
  today,

  /// After today.
  future,
}

/// One calendar day.
class DayHistory {
  /// Creates a day.
  const DayHistory({
    required this.date,
    required this.adherence,
    required this.doses,
    required this.intakes,
  });

  /// Local date (device zone).
  final LocalDate date;

  /// Colour class.
  final DayAdherence adherence;

  /// Scheduled doses of the day with their status.
  final List<ScheduledDose> doses;

  /// As-needed intakes (taken events without occurrence) of the day.
  final List<DoseEventRow> intakes;
}

/// A month of history with summary numbers.
class MonthHistory {
  /// Creates a month.
  const MonthHistory({
    required this.month,
    required this.days,
    required this.adherencePercent,
  });

  /// First day of the month.
  final LocalDate month;

  /// Every day of the month, in order.
  final List<DayHistory> days;

  /// Taken / due doses up to now, in percent; null when nothing was due.
  final int? adherencePercent;

  /// The day [date] of this month, if any.
  DayHistory? day(LocalDate date) {
    for (final day in days) {
      if (day.date == date) {
        return day;
      }
    }
    return null;
  }
}

/// The device-local date a dose belongs to.
LocalDate doseDay(ScheduledDose dose, String deviceTz) => dose.zone == deviceTz
    ? dose.occurrence.localDate
    : wallClockOf(dose.dueAt, deviceTz).date;

/// Colour class of [date] from its [doses].
DayAdherence dayAdherence(
  LocalDate date,
  LocalDate today,
  List<ScheduledDose> doses,
) {
  if (date.isAfter(today)) {
    return DayAdherence.future;
  }
  if (date == today) {
    return DayAdherence.today;
  }
  if (doses.isEmpty) {
    return DayAdherence.empty;
  }
  final taken = doses.where((d) => d.status == DoseStatus.taken).length;
  if (taken == doses.length) {
    return DayAdherence.allTaken;
  }
  return taken > 0 ? DayAdherence.partial : DayAdherence.missed;
}

/// Groups [doses] and as-needed [events] by device-local day in
/// `[first, last]` and classifies each day.
List<DayHistory> buildDays({
  required LocalDate first,
  required LocalDate last,
  required List<ScheduledDose> doses,
  required List<DoseEventRow> events,
  required String deviceTz,
  required LocalDate today,
}) {
  final dosesByDay = <LocalDate, List<ScheduledDose>>{};
  for (final dose in doses) {
    (dosesByDay[doseDay(dose, deviceTz)] ??= <ScheduledDose>[]).add(dose);
  }
  final intakesByDay = <LocalDate, List<DoseEventRow>>{};
  final medicationIds = {for (final event in events) event.medicationId};
  for (final medicationId in medicationIds) {
    for (final event in asNeededIntakes(events, medicationId)) {
      final at = DateTime.fromMicrosecondsSinceEpoch(event.at, isUtc: true);
      (intakesByDay[localDateOf(at, deviceTz)] ??= <DoseEventRow>[]).add(event);
    }
  }
  return [
    for (var day = first; !day.isAfter(last); day = day.addDays(1))
      DayHistory(
        date: day,
        adherence: dayAdherence(day, today, dosesByDay[day] ?? const []),
        doses: dosesByDay[day] ?? const [],
        intakes: intakesByDay[day] ?? const [],
      ),
  ];
}

/// Taken share of the doses that are no longer pending, in percent.
int? adherencePercent(Iterable<ScheduledDose> doses) {
  var due = 0;
  var taken = 0;
  for (final dose in doses) {
    if (dose.status == DoseStatus.pending) {
      continue;
    }
    due++;
    if (dose.status == DoseStatus.taken) {
      taken++;
    }
  }
  return due == 0 ? null : (taken * 100 / due).round();
}

/// Consecutive fully-taken days ending yesterday (or today, if today is
/// already fully taken). Days without doses neither count nor break it.
int adherenceStreak(List<DayHistory> days, LocalDate today) {
  var streak = 0;
  for (final day in days.reversed) {
    if (day.date.isAfter(today)) {
      continue;
    }
    if (day.date == today) {
      final all = day.doses.isNotEmpty &&
          day.doses.every((d) => d.status == DoseStatus.taken);
      if (all) {
        streak++;
      }
      continue;
    }
    switch (day.adherence) {
      case DayAdherence.allTaken:
        streak++;
      case DayAdherence.empty:
        continue;
      case DayAdherence.partial:
      case DayAdherence.missed:
      case DayAdherence.today:
      case DayAdherence.future:
        return streak;
    }
  }
  return streak;
}
