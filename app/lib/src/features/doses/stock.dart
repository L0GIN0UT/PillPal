import 'package:pillpal_core/pillpal_core.dart';

import '../../data/db/database.dart';
import 'dose_status.dart';

/// Average amount taken per day under [rule] (TZ §2.4 "осталось на N дней").
///
/// Stock is assumed to be counted in the schedule's dose units.
double dailyConsumption(ScheduleRule rule) {
  final perDay = rule.times.fold<double>(
    0,
    (sum, slot) => sum + (double.tryParse(slot.dose.amount) ?? 0),
  );
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

/// Whole days the stock of [medication] lasts under [rules] (active on
/// [today]), or null when stock is not tracked or nothing is scheduled.
int? stockDaysLeft(
  MedicationRow medication,
  Iterable<ScheduleRule> rules,
  LocalDate today,
) {
  final stock = double.tryParse(medication.stockCount ?? '');
  if (stock == null) {
    return null;
  }
  final perDay = rules
      .where((rule) {
        final end = rule.endDate;
        return end == null || !end.isBefore(today);
      })
      .map(dailyConsumption)
      .fold<double>(0, (sum, value) => sum + value);
  if (perDay <= 0) {
    return null;
  }
  return (stock / perDay).floor();
}

/// Whether [daysLeft] is at or below the medication's warning threshold.
bool isLowStock(MedicationRow medication, int? daysLeft) {
  if (daysLeft == null) {
    return false;
  }
  final threshold = medication.lowStockDays ?? DoseTiming.defaultLowStockDays;
  return daysLeft <= threshold;
}
