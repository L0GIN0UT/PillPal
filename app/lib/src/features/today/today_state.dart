import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../data/db/database.dart';
import '../common/local_time.dart';
import '../doses/dose_providers.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';
import '../doses/stock.dart';

/// An as-needed medication with today's intakes.
class AsNeededMedication {
  /// Creates an entry.
  const AsNeededMedication(this.medication, this.intakesToday, this.lastAt);

  /// The medication.
  final MedicationRow medication;

  /// Intakes recorded today.
  final int intakesToday;

  /// Latest intake today (UTC), if any.
  final DateTime? lastAt;
}

/// A medication that runs out soon.
class LowStockMedication {
  /// Creates an entry.
  const LowStockMedication(this.medication, this.daysLeft);

  /// The medication.
  final MedicationRow medication;

  /// Whole days of stock left.
  final int daysLeft;
}

/// Everything the Today screen shows.
class TodayState {
  /// Creates the state.
  const TodayState({
    required this.date,
    required this.doses,
    required this.asNeeded,
    required this.lowStock,
    required this.hasMedications,
    required this.now,
  });

  /// Local date shown.
  final LocalDate date;

  /// Today's scheduled doses by time.
  final List<ScheduledDose> doses;

  /// As-needed medications.
  final List<AsNeededMedication> asNeeded;

  /// Medications running low.
  final List<LowStockMedication> lowStock;

  /// Whether the profile has any medication.
  final bool hasMedications;

  /// The instant the state was computed for.
  final DateTime now;

  /// Doses marked taken.
  int get takenCount =>
      doses.where((dose) => dose.status == DoseStatus.taken).length;

  /// The next dose still due after [now].
  ScheduledDose? get nextDose {
    for (final dose in doses) {
      if (dose.status == DoseStatus.pending && dose.dueAt.isAfter(now)) {
        return dose;
      }
    }
    return null;
  }

  /// The dose to take now: the earliest open dose that is already due,
  /// otherwise the next one.
  ScheduledDose? get currentDose {
    for (final dose in doses) {
      if (dose.isOpen && !dose.dueAt.isAfter(now)) {
        return dose;
      }
    }
    return nextDose;
  }
}

/// Builds [TodayState] from the stored rows (pure; see `todayProvider`).
TodayState buildTodayState({
  required List<MedicationRow> medications,
  required List<ParsedSchedule> schedules,
  required List<DoseEventRow> events,
  required String deviceTz,
  required DateTime now,
}) {
  final today = localDateOf(now, deviceTz);
  final medicationIds = {for (final m in medications) m.id};
  final own = [
    for (final s in schedules)
      if (medicationIds.contains(s.row.medicationId)) s,
  ];
  final bounds = dayBounds(today, deviceTz);
  final doses = buildScheduledDoses(
    medications: medications,
    schedules: own,
    events: events,
    deviceTz: deviceTz,
    start: bounds.start,
    end: bounds.end,
    now: now,
  );
  final todayEvents = events.where((event) {
    final at = DateTime.fromMicrosecondsSinceEpoch(event.at, isUtc: true);
    return !at.isBefore(bounds.start) && at.isBefore(bounds.end);
  }).toList();
  final asNeeded = <AsNeededMedication>[];
  final lowStock = <LowStockMedication>[];
  for (final medication in medications) {
    final rules = [
      for (final s in own)
        if (s.row.medicationId == medication.id) s.rule,
    ];
    // Ended or not yet started as-needed schedules are not offered (ADR 0003).
    if (rules.any(
      (rule) => rule.kind == RuleKind.asNeeded && isRunningOn(rule, today),
    )) {
      final intakes = asNeededIntakes(todayEvents, medication.id);
      asNeeded.add(
        AsNeededMedication(
          medication,
          intakes.length,
          intakes.isEmpty
              ? null
              : DateTime.fromMicrosecondsSinceEpoch(
                  intakes.last.at,
                  isUtc: true,
                ),
        ),
      );
    }
    final daysLeft = stockDaysLeft(medication, rules, today);
    if (daysLeft != null && isLowStock(medication, daysLeft)) {
      lowStock.add(LowStockMedication(medication, daysLeft));
    }
  }
  return TodayState(
    date: today,
    doses: doses,
    asNeeded: asNeeded,
    lowStock: lowStock,
    hasMedications: medications.isNotEmpty,
    now: now,
  );
}

/// Today's doses for the self profile, recomputed when rows or "now" change.
///
/// Loading until the device zone is known, so no dose is first shown at a
/// time computed in a guessed zone.
final todayProvider = Provider.autoDispose<AsyncValue<TodayState>>((ref) {
  if (!ref.watch(deviceTimeZoneReadyProvider)) {
    return const AsyncLoading();
  }
  final now = ref.watch(nowProvider);
  final tz = ref.watch(deviceTimeZoneProvider);
  final today = localDateOf(now, tz);
  final events = ref.watch(
    doseEventsForDaysProvider(dayWindow(today, today, tz)),
  );
  return combine3(
    ref.watch(selfMedicationsProvider),
    ref.watch(parsedSchedulesProvider),
    events,
    (medications, schedules, rows) => buildTodayState(
      medications: medications,
      schedules: schedules,
      events: rows,
      deviceTz: tz,
      now: now,
    ),
  );
});
