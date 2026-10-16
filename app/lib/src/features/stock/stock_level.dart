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
/// [events] its dose events, of which those recorded after the baseline
/// count: the effective `taken` mark of each occurrence (ADR 0003 §6) with
/// the dose of its time slot, and as-needed intakes not undone. Days left
/// divide by the average daily consumption of the schedules running on
/// [today].
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
  final recent = [
    for (final event in events)
      if (event.medicationId == medication.id && event.at > since) event,
  ];
  final scheduled = _scheduledTakenMilli(recent, schedules, unit);
  if (scheduled == null) {
    return const StockUnknown(StockProblem.unitMismatch);
  }
  final intakes = asNeededIntakes(recent, medication.id).length;
  var asNeeded = 0;
  if (intakes > 0) {
    final dose = asNeededDoseMilli(schedules, unit);
    if (dose == null) {
      return const StockUnknown(StockProblem.unknownIntakeDose);
    }
    asNeeded = dose * intakes;
  }
  final perDay = _dailyMilli(schedules, unit, today);
  if (perDay == null) {
    return const StockUnknown(StockProblem.unitMismatch);
  }
  final remaining = count - scheduled - asNeeded;
  return StockKnown(
    remainingMilli: remaining,
    unit: unit,
    daysLeft:
        perDay <= 0 ? null : ((remaining < 0 ? 0 : remaining) / perDay).floor(),
  );
}

/// Thousandths taken at scheduled occurrences among [events]; null when a
/// taken dose is in another unit than [unit].
int? _scheduledTakenMilli(
  List<DoseEventRow> events,
  List<ParsedSchedule> schedules,
  DoseUnit unit,
) {
  final rules = {for (final s in schedules) s.row.id: s.rule};
  // Undos normally carry their target's key; any that do not still apply.
  final undos = [
    for (final event in events)
      if (event.eventType == DoseEventType.undo.wire) event,
  ];
  var total = 0;
  for (final entry in eventsByOccurrence(events).entries) {
    final mark = effectiveMark([...entry.value, ...undos]);
    if (mark == null || mark.type != DoseEventType.taken) {
      continue;
    }
    final dose = _slotDose(rules, entry.key);
    // A deleted schedule, or a slot whose time was edited the same day, no
    // longer has a dose: its marks count nowhere (ADR 0003 §2, §3).
    if (dose == null) {
      continue;
    }
    if (dose.unit != unit) {
      return null;
    }
    total += parseMilli(dose.amount) ?? 0;
  }
  return total;
}

/// The dose of occurrence [key] (`{schedule_id}/{date}T{HH:MM}`).
Dose? _slotDose(Map<String, ScheduleRule> rules, String key) {
  final separator = key.indexOf('/');
  final timeStart = key.lastIndexOf('T');
  if (separator < 0 || timeStart < separator) {
    return null;
  }
  final rule = rules[key.substring(0, separator)];
  final time = key.substring(timeStart + 1);
  for (final slot in rule?.times ?? const <TimeSlot>[]) {
    if (slot.time == time) {
      return slot.dose;
    }
  }
  return null;
}

/// The dose of one as-needed intake in thousandths of [unit]: the dose of
/// the medication's time slots when they all agree, one piece of a counted
/// [unit] when it has none; null otherwise (the intake records no dose).
int? asNeededDoseMilli(List<ParsedSchedule> schedules, DoseUnit unit) {
  final doses = {
    for (final schedule in schedules)
      for (final slot in schedule.rule.times)
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

/// Average thousandths consumed per day by the schedules running on [today];
/// null when one of them doses in another unit than [unit].
double? _dailyMilli(
  List<ParsedSchedule> schedules,
  DoseUnit unit,
  LocalDate today,
) {
  var total = 0.0;
  for (final schedule in schedules) {
    final rule = schedule.rule;
    if (!isRunningOn(rule, today)) {
      continue;
    }
    if (rule.times.any((slot) => slot.dose.unit != unit)) {
      return null;
    }
    total += dailyConsumption(rule) * milliPerUnit;
  }
  return total;
}

/// Average amount taken per day under [rule] (TZ §2.4 "осталось на N дней").
double dailyConsumption(ScheduleRule rule) {
  final perDay = rule.times.fold<int>(
        0,
        (sum, slot) => sum + (parseMilli(slot.dose.amount) ?? 0),
      ) /
      milliPerUnit;
  switch (rule.kind) {
    case RuleKind.daily:
      return perDay;
    case RuleKind.weekdays:
      final days = rule.weekdays?.length ?? 0;
      return perDay * days / DateTime.daysPerWeek;
    case RuleKind.intervalDays:
      final interval = rule.intervalDays ?? 1;
      return perDay / interval;
    case RuleKind.asNeeded:
      return 0;
  }
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
