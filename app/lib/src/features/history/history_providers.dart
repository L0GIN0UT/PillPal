import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../data/db/database.dart';
import '../common/local_time.dart';
import '../doses/dose_providers.dart';
import '../doses/scheduled_doses.dart';
import 'history_model.dart';

/// Days looked back for the "days in a row" counter.
const int streakLookbackDays = 120;

/// The month shown in History (first day); null means the current month.
final historyMonthProvider = NotifierProvider<HistoryMonth, LocalDate?>(
  HistoryMonth.new,
);

/// Month navigation of the History screen.
class HistoryMonth extends Notifier<LocalDate?> {
  @override
  LocalDate? build() => null;

  /// Shows the month of [day].
  void show(LocalDate day) {
    state = monthStart(day);
  }
}

/// The day whose details History lists; null shows none.
final historySelectedDayProvider =
    NotifierProvider<HistorySelectedDay, LocalDate?>(HistorySelectedDay.new);

/// Selected day of the History calendar.
class HistorySelectedDay extends Notifier<LocalDate?> {
  @override
  LocalDate? build() => null;

  /// Selects [day] (or clears with null).
  void select(LocalDate? day) {
    state = day;
  }
}

/// Day histories of `[first, last]` (device-local dates); loading until the
/// device zone is known.
final dayRangeProvider = Provider.autoDispose
    .family<AsyncValue<List<DayHistory>>, ({LocalDate first, LocalDate last})>(
  (ref, range) {
    if (!ref.watch(deviceTimeZoneReadyProvider)) {
      return const AsyncLoading();
    }
    final tz = ref.watch(deviceTimeZoneProvider);
    final now = ref.watch(nowProvider);
    final window = dayWindow(range.first, range.last, tz);
    return combine3(
      ref.watch(selfMedicationsProvider),
      ref.watch(parsedSchedulesProvider),
      ref.watch(doseEventsForDaysProvider(window)),
      (medications, schedules, rows) => buildHistoryDays(
        medications: medications,
        schedules: schedules,
        events: rows,
        window: window,
        deviceTz: tz,
        now: now,
      ),
    );
  },
);

/// Day histories of [window] from the stored rows (pure; see
/// [dayRangeProvider]). Ended schedules count like running ones: expansion
/// stops at their `end_date` (ADR 0003 §4).
List<DayHistory> buildHistoryDays({
  required List<MedicationRow> medications,
  required List<ParsedSchedule> schedules,
  required List<DoseEventRow> events,
  required DayWindow window,
  required String deviceTz,
  required DateTime now,
}) {
  final doses = buildScheduledDoses(
    medications: medications,
    schedules: schedules,
    events: events,
    deviceTz: deviceTz,
    start: window.from,
    end: window.to,
    now: now,
  );
  final ownIds = {for (final m in medications) m.id};
  return buildDays(
    first: window.first,
    last: window.last,
    doses: doses,
    events: [
      for (final row in events)
        if (ownIds.contains(row.medicationId)) row,
    ],
    deviceTz: deviceTz,
    today: localDateOf(now, deviceTz),
  );
}

/// The month shown in History with its adherence.
final monthHistoryProvider =
    Provider.autoDispose<AsyncValue<MonthHistory>>((ref) {
  final today = ref.watch(todayDateProvider);
  final month = ref.watch(historyMonthProvider) ?? monthStart(today);
  final last = nextMonthStart(month).addDays(-1);
  return ref.watch(dayRangeProvider((first: month, last: last))).whenData(
        (days) => MonthHistory(
          month: month,
          days: days,
          adherencePercent: adherencePercent(days.expand((d) => d.doses)),
        ),
      );
});

/// Fully-taken days in a row up to today.
final adherenceStreakProvider = Provider.autoDispose<AsyncValue<int>>((ref) {
  final today = ref.watch(todayDateProvider);
  final first = today.addDays(-streakLookbackDays);
  return ref
      .watch(dayRangeProvider((first: first, last: today)))
      .whenData((days) => adherenceStreak(days, today));
});
