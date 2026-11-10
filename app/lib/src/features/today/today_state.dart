import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../data/db/database.dart';
import '../../data/repositories/local_writer.dart';
import '../common/local_time.dart';
import '../doses/dose_providers.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';
import '../family/profile_context.dart';
import '../stock/stock_level.dart';
import '../stock/stock_providers.dart';

/// An as-needed medication with today's intakes.
class AsNeededMedication {
  /// Creates an entry.
  const AsNeededMedication(
    this.medication,
    this.intakesToday,
    this.lastAt, {
    required this.displayZone,
    this.lastEventId,
  });

  /// The medication.
  final MedicationRow medication;

  /// Intakes recorded today.
  final int intakesToday;

  /// Latest intake today (UTC), if any.
  final DateTime? lastAt;

  /// The event of the latest intake today (target of an undo), if any.
  final String? lastEventId;

  /// The zone [lastAt] is shown in.
  final String displayZone;
}

/// A medication that runs out soon.
class LowStockMedication {
  /// Creates an entry.
  const LowStockMedication(this.medication, this.stock);

  /// The medication.
  final MedicationRow medication;

  /// Its stock.
  final StockKnown stock;

  /// Whole days of stock left.
  int get daysLeft => stock.daysLeft ?? 0;
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

/// Today's doses as the screen lays them out: the «Сейчас» card, «Дальше»
/// and «Уже было» (B2-README section 8).
typedef TodaySections = ({
  ScheduledDose? hero,
  List<ScheduledDose> upcoming,
  List<ScheduledDose> past,
});

/// Splits [TodayState.doses] into [TodaySections]; every dose lands in
/// exactly one of them, in time order.
///
/// The hero is the dose to take now: the earliest pending dose that is due,
/// else the next pending one. A missed dose is not the hero (the board shows
/// it among the earlier ones, where a tap offers take or skip), which is why
/// this is not [TodayState.currentDose]. Taken, skipped and missed doses are
/// the earlier ones; the rest wait in «Дальше».
///
/// [withHero] false (a relative's day view: viewers and editors never mark)
/// leaves the hero out and keeps that dose first among the upcoming ones.
TodaySections todaySections(TodayState state, {bool withHero = true}) {
  final hero = withHero ? _heroOf(state) : null;
  final upcoming = <ScheduledDose>[];
  final past = <ScheduledDose>[];
  for (final dose in state.doses) {
    if (identical(dose, hero)) {
      continue;
    }
    (dose.status == DoseStatus.pending ? upcoming : past).add(dose);
  }
  return (hero: hero, upcoming: upcoming, past: past);
}

ScheduledDose? _heroOf(TodayState state) {
  for (final dose in state.doses) {
    if (dose.status == DoseStatus.pending && !dose.dueAt.isAfter(state.now)) {
      return dose;
    }
  }
  return state.nextDose;
}

/// Builds [TodayState] from the stored rows (pure; see `todayProvider`).
TodayState buildTodayState({
  required List<MedicationRow> medications,
  required List<ParsedSchedule> schedules,
  required List<DoseEventRow> events,
  required String deviceTz,
  required DateTime now,
  Map<String, StockLevel> stock = const {},
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
    // A redacted medication (no name) has nothing to offer to anyone.
    final offersAsNeeded = !medication.redacted &&
        rules.any(
          (rule) => rule.kind == RuleKind.asNeeded && isRunningOn(rule, today),
        );
    if (offersAsNeeded) {
      final intakes = asNeededIntakes(todayEvents, medication.id);
      final last = intakes.isEmpty ? null : intakes.last;
      asNeeded.add(
        AsNeededMedication(
          medication,
          intakes.length,
          last == null ? null : microsToInstant(last.at),
          displayZone: deviceTz,
          lastEventId: last?.id,
        ),
      );
    }
    final level = stock[medication.id];
    if (level is StockKnown && isLowStock(medication, level)) {
      lowStock.add(LowStockMedication(medication, level));
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

/// Today's doses of profile [profileId] (null: the user's own `self`
/// profile), recomputed when rows or "now" change.
///
/// Loading until the device zone is known, so no dose is first shown at a
/// time computed in a guessed zone. The day and the times are those of the
/// zone the profile's `local` medications follow: the device zone for the
/// user's own profile, the profile's zone for any other (D4), the same rule
/// as the reminder planner (`ProfileAccess.localZone`).
final todayStateProvider = Provider.autoDispose
    .family<AsyncValue<TodayState>, String?>((ref, profileId) {
  if (!ref.watch(deviceTimeZoneReadyProvider)) {
    return const AsyncLoading();
  }
  final accessValue = ref.watch(profileAccessProvider(profileId));
  if (accessValue.isLoading && !accessValue.hasValue) {
    return const AsyncLoading();
  }
  final access = accessValue.valueOrNull;
  final now = ref.watch(nowProvider);
  final deviceTz = ref.watch(deviceTimeZoneProvider);
  final tz = access?.localZone(deviceTz) ?? deviceTz;
  final today = localDateOf(now, tz);
  final events = ref.watch(
    doseEventsForDaysProvider(
      (profileId: profileId, window: dayWindow(today, today, tz)),
    ),
  );
  // Stock is secondary: Today does not wait for it. It is tracked for the
  // user's own profile only.
  final stock = access == null || access.isOwnSelf
      ? ref.watch(stockLevelsProvider).valueOrNull ?? const {}
      : const <String, StockLevel>{};
  return combine3(
    ref.watch(profileMedicationsProvider(profileId)),
    ref.watch(profileSchedulesProvider(profileId)),
    events,
    (medications, schedules, rows) => buildTodayState(
      medications: medications,
      schedules: schedules,
      events: rows,
      deviceTz: tz,
      now: now,
      stock: stock,
    ),
  );
});

/// Today's doses of the user's own profile.
final todayProvider = todayStateProvider(null);
