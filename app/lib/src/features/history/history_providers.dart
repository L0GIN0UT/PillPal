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

/// Today's local date in the device zone.
final todayDateProvider = Provider<LocalDate>(
  (ref) =>
      localDateOf(ref.watch(nowProvider), ref.watch(deviceTimeZoneProvider)),
);

/// Day histories of `[first, last]` (device-local dates).
final dayRangeProvider = Provider.family<AsyncValue<List<DayHistory>>,
    ({LocalDate first, LocalDate last})>(
  (ref, range) {
    final tz = ref.watch(deviceTimeZoneProvider);
    final now = ref.watch(nowProvider);
    final today = localDateOf(now, tz);
    final start = dayBounds(range.first, tz).start;
    final end = dayBounds(range.last, tz).end;
    const margin = Duration(days: 1);
    final events = ref.watch(
      doseEventsProvider((from: start.subtract(margin), to: end.add(margin))),
    );
    return combine3(
      ref.watch(selfMedicationsProvider),
      ref.watch(parsedSchedulesProvider),
      events,
      (List<MedicationRow> medications, List<ParsedSchedule> schedules,
          List<DoseEventRow> rows) {
        final doses = buildScheduledDoses(
          medications: medications,
          schedules: schedules,
          events: rows,
          deviceTz: tz,
          start: start,
          end: end,
          now: now,
        );
        final ownIds = {for (final m in medications) m.id};
        return buildDays(
          first: range.first,
          last: range.last,
          doses: doses,
          events: [
            for (final row in rows)
              if (ownIds.contains(row.medicationId)) row,
          ],
          deviceTz: tz,
          today: today,
        );
      },
    );
  },
);

/// The month shown in History with its adherence.
final monthHistoryProvider = Provider<AsyncValue<MonthHistory>>((ref) {
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
final adherenceStreakProvider = Provider<AsyncValue<int>>((ref) {
  final today = ref.watch(todayDateProvider);
  final first = today.addDays(-streakLookbackDays);
  return ref
      .watch(dayRangeProvider((first: first, last: today)))
      .whenData((days) => adherenceStreak(days, today));
});
