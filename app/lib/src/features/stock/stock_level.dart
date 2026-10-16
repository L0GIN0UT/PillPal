import 'package:pillpal_core/pillpal_core.dart';

import '../../data/db/database.dart';
import '../../data/repositories/dose_events_repository.dart';
import '../../data/repositories/medications_repository.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';

// Stock tracking (TZ §2.4, docs/adr/0004-stock-tracking.md). The stock is
// never decremented in the database: a synced counter written by two
// devices under last-write-wins would lose decrements. The remaining amount
// is derived instead from the user-entered baseline (`stock_count` at
// `stock_set_at`) minus the doses taken after it. Amounts are exact decimals
// with at most 3 fraction digits, so they are summed as integer thousandths.

/// Thousandths in one unit of an amount.
const int milliPerUnit = 1000;

/// Units that are counted in pieces: an as-needed intake without a known
/// dose is one piece of them.
const Set<DoseUnit> countedUnits = {
  DoseUnit.tablet,
  DoseUnit.capsule,
  DoseUnit.drop,
  DoseUnit.puff,
  DoseUnit.sachet,
  DoseUnit.unit,
  DoseUnit.injection,
};

/// Why the remaining stock cannot be computed.
enum StockProblem {
  /// The stock unit is not one of the dose units (free text, legacy rows).
  unknownUnit,

  /// A dose to subtract or a running schedule uses another unit.
  unitMismatch,

  /// An as-needed intake has no derivable dose.
  unknownIntakeDose,

  /// A dose was taken from a schedule that no longer exists.
  unknownSchedule,
}

/// What is known about a medication's stock.
sealed class StockLevel {
  const StockLevel();
}

/// Stock is not tracked for the medication.
final class StockNotTracked extends StockLevel {
  /// Creates the value.
  const StockNotTracked();
}

/// Stock is tracked but cannot be computed ("не удаётся посчитать").
final class StockUnknown extends StockLevel {
  /// Creates the value.
  const StockUnknown(this.problem);

  /// Why.
  final StockProblem problem;
}

/// The remaining stock and how long it lasts.
final class StockKnown extends StockLevel {
  /// Creates the value.
  const StockKnown({
    required this.remainingMilli,
    required this.unit,
    required this.daysLeft,
  });

  /// Remaining amount in thousandths; negative when more was taken than
  /// counted (shown as zero).
  final int remainingMilli;

  /// The stock unit (one of the dose units).
  final DoseUnit unit;

  /// Whole days left at the current consumption; null when nothing running
  /// consumes it (as-needed only, or no running schedule).
  final int? daysLeft;

  /// The remaining amount as a decimal string ("12.5"), never negative.
  String get remaining => formatMilli(remainingMilli < 0 ? 0 : remainingMilli);
}

final RegExp _decimal = RegExp(r'^([0-9]{1,9})(?:\.([0-9]{1,3}))?$');

/// [value] ("12.5") in thousandths (12500), or null if it is not a decimal
/// with at most 3 fraction digits.
int? parseMilli(String? value) {
  final match = value == null ? null : _decimal.firstMatch(value.trim());
  if (match == null) {
    return null;
  }
  final fraction = (match.group(2) ?? '').padRight(3, '0');
  return int.parse(match.group(1)!) * milliPerUnit + int.parse(fraction);
}

/// Thousandths as a normalised decimal string (12500 -> "12.5").
String formatMilli(int milli) {
  final whole = milli ~/ milliPerUnit;
  final fraction = (milli % milliPerUnit).toString().padLeft(3, '0');
  final trimmed = fraction.replaceFirst(RegExp(r'0+$'), '');
  return trimmed.isEmpty ? '$whole' : '$whole.$trimmed';
}

/// The stock unit of [medication] as a dose unit, or null (free text).
DoseUnit? stockUnitOf(MedicationRow medication) =>
    DoseUnit.values.asNameMap()[medication.stockUnit];

/// The remaining stock of [medication] (pure; see `stockLevelsProvider`).
///
/// [schedules] are the medication's live schedules (ended ones included);
/// [events] its dose events. Undos apply whenever they were loaded; what
/// counts is recorded after the baseline: the effective `taken` mark of each
/// occurrence (ADR 0003 §6) with the dose of its time slot, and as-needed
/// intakes not undone. Days left use the average consumption of the
/// schedules running on [today], in integer arithmetic.
StockLevel computeStock({
  required MedicationRow medication,
  required List<ParsedSchedule> schedules,
  required Iterable<DoseEventRow> events,
  required LocalDate today,
}) {
  final count = parseMilli(medication.stockCount);
  final baseline = stockBaselineOf(medication);
  if (count == null || baseline == null) {
    return const StockNotTracked();
  }
  final unit = stockUnitOf(medication);
  if (unit == null) {
    return const StockUnknown(StockProblem.unknownUnit);
  }
  final since = baseline.microsecondsSinceEpoch;
  final own = [
    for (final event in events)
      if (event.medicationId == medication.id) event,
  ];
  final scheduled = _scheduledTaken(own, schedules, unit, since);
  final problem = scheduled.problem;
  if (problem != null) {
    return StockUnknown(problem);
  }
  final running = [
    for (final schedule in schedules)
      if (isRunningOn(schedule.rule, today)) schedule.rule,
  ];
  final intakes = asNeededIntakes(own, medication.id)
      .where((event) => event.at > since)
      .length;
  var asNeeded = 0;
  if (intakes > 0) {
    final dose = asNeededDoseMilli(running, unit);
    if (dose == null) {
      return const StockUnknown(StockProblem.unknownIntakeDose);
    }
    asNeeded = dose * intakes;
  }
  if (running.any((rule) => rule.times.any((s) => s.dose.unit != unit))) {
    return const StockUnknown(StockProblem.unitMismatch);
  }
  final rate = consumptionRate(running);
  final remaining = count - scheduled.milli - asNeeded;
  return StockKnown(
    remainingMilli: remaining,
    unit: unit,
    daysLeft: rate.milli <= 0
        ? null
        : (remaining < 0 ? 0 : remaining) * rate.days ~/ rate.milli,
  );
}

/// Thousandths taken at scheduled occurrences after [since], or why they
/// cannot be counted.
({int milli, StockProblem? problem}) _scheduledTaken(
  List<DoseEventRow> events,
  List<ParsedSchedule> schedules,
  DoseUnit unit,
  int since,
) {
  final rules = {for (final s in schedules) s.row.id: s.rule};
  // Undos normally carry their target's key; any that do not still apply.
  final undos = [
    for (final event in events)
      if (event.eventType == DoseEventType.undo.wire &&
          event.occurrenceKey == null)
        event,
  ];
  var total = 0;
  for (final entry in eventsByOccurrence(events).entries) {
    final mark = effectiveMark([...entry.value, ...undos]);
    if (mark == null ||
        mark.type != DoseEventType.taken ||
        mark.at.microsecondsSinceEpoch <= since) {
      continue;
    }
    final rule = rules[_scheduleIdOf(entry.key)];
    // A dose taken from a schedule that is gone (deleted "with history", or
    // not synced yet) has an unknown amount: counting nothing would inflate
    // the stock (docs/adr/0004-stock-tracking.md).
    if (rule == null) {
      return (milli: 0, problem: StockProblem.unknownSchedule);
    }
    final dose = _slotDose(rule, entry.key);
    // A slot whose time was edited the same day no longer has a dose; its
    // mark does not carry over (ADR 0003 §2).
    if (dose == null) {
      continue;
    }
    if (dose.unit != unit) {
      return (milli: 0, problem: StockProblem.unitMismatch);
    }
    total += parseMilli(dose.amount) ?? 0;
  }
  return (milli: total, problem: null);
}

/// The schedule id of occurrence [key] (`{schedule_id}/{date}T{HH:MM}`).
String _scheduleIdOf(String key) {
  final separator = key.indexOf('/');
  return separator < 0 ? key : key.substring(0, separator);
}

/// The dose of occurrence [key] under [rule].
Dose? _slotDose(ScheduleRule rule, String key) {
  final timeStart = key.lastIndexOf('T');
  if (timeStart < 0) {
    return null;
  }
  final time = key.substring(timeStart + 1);
  for (final slot in rule.times) {
    if (slot.time == time) {
      return slot.dose;
    }
  }
  return null;
}

/// The dose of one as-needed intake in thousandths of [unit]: the dose of
/// the time slots of the [running] schedules when they all agree, one
/// piece of a counted [unit] when they have none; null otherwise (the
/// intake records no dose).
int? asNeededDoseMilli(Iterable<ScheduleRule> running, DoseUnit unit) {
  final doses = {
    for (final rule in running)
      for (final slot in rule.times)
        (amount: slot.dose.amount, unit: slot.dose.unit),
  };
  if (doses.isEmpty) {
    return countedUnits.contains(unit) ? milliPerUnit : null;
  }
  if (doses.length > 1 || doses.single.unit != unit) {
    return null;
  }
  return parseMilli(doses.single.amount);
}

/// What [rule] consumes per period, in thousandths: per day (`daily`), per
/// week (`weekdays`), per interval (`interval_days`); nothing for
/// `as_needed`.
({int milli, int days}) periodConsumption(ScheduleRule rule) {
  final perDose = rule.times.fold<int>(
    0,
    (sum, slot) => sum + (parseMilli(slot.dose.amount) ?? 0),
  );
  switch (rule.kind) {
    case RuleKind.daily:
      return (milli: perDose, days: 1);
    case RuleKind.weekdays:
      final days = rule.weekdays?.length ?? 0;
      return (milli: perDose * days, days: DateTime.daysPerWeek);
    case RuleKind.intervalDays:
      return (milli: perDose, days: rule.intervalDays ?? 1);
    case RuleKind.asNeeded:
      return (milli: 0, days: 1);
  }
}

/// The combined consumption of [rules] as thousandths per [days] days
/// (an exact fraction: no floating point, ADR 0004).
({int milli, int days}) consumptionRate(Iterable<ScheduleRule> rules) {
  final periods = [for (final rule in rules) periodConsumption(rule)];
  final days =
      periods.fold<int>(1, (lcm, p) => lcm * p.days ~/ lcm.gcd(p.days));
  var milli = 0;
  for (final period in periods) {
    milli += period.milli * (days ~/ period.days);
  }
  return (milli: milli, days: days);
}

/// Whether [level] lasts at most the medication's warning threshold.
bool isLowStock(MedicationRow medication, StockLevel level) {
  if (level is! StockKnown) {
    return false;
  }
  final days = level.daysLeft;
  if (days == null) {
    return false;
  }
  final threshold = medication.lowStockDays ?? DoseTiming.defaultLowStockDays;
  return days <= threshold;
}
