import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../data/db/database.dart';
import '../common/local_time.dart';
import '../doses/dose_providers.dart';
import '../doses/scheduled_doses.dart';
import '../family/profile_context.dart';
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

/// Days of profile [profileId] (null: the user's own `self` profile): the
/// local dates `[first, last]` in the zone the profile is read in.
typedef ProfileRange = ({String? profileId, LocalDate first, LocalDate last});

/// Day histories of a [ProfileRange]; loading until the device zone is
/// known. The dates and times are those of the zone the profile's `local`
/// medications follow (D4), like on Today.
final dayRangeProvider = Provider.autoDispose
    .family<AsyncValue<List<DayHistory>>, ProfileRange>(
  (ref, range) {
    if (!ref.watch(deviceTimeZoneReadyProvider)) {
      return const AsyncLoading();
    }
    final profileId = range.profileId;
    final accessValue = ref.watch(profileAccessProvider(profileId));
    if (accessValue.isLoading && !accessValue.hasValue) {
      return const AsyncLoading();
    }
    final tz = accessValue.valueOrNull
            ?.localZone(ref.watch(deviceTimeZoneProvider)) ??
        ref.watch(deviceTimeZoneProvider);
    final now = ref.watch(nowProvider);
    final window = dayWindow(range.first, range.last, tz);
    return combine3(
      ref.watch(profileMedicationsProvider(profileId)),
      ref.watch(profileSchedulesProvider(profileId)),
      ref.watch(
        doseEventsForDaysProvider((profileId: profileId, window: window)),
      ),
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

/// The zone [profileId]'s History reads its days in (the viewing zone).
final historyZoneProvider =
    Provider.autoDispose.family<String, String?>((ref, profileId) {
  final deviceTz = ref.watch(deviceTimeZoneProvider);
  final access = ref.watch(profileAccessProvider(profileId)).valueOrNull;
  return access?.localZone(deviceTz) ?? deviceTz;
});

/// The month shown in History of [profileId] with its adherence.
final monthHistoryProvider = Provider.autoDispose
    .family<AsyncValue<MonthHistory>, String?>((ref, profileId) {
  final zone = ref.watch(historyZoneProvider(profileId));
  final today = localDateOf(ref.watch(nowProvider), zone);
  final month = ref.watch(historyMonthProvider) ?? monthStart(today);
  final last = nextMonthStart(month).addDays(-1);
  return ref
      .watch(
        dayRangeProvider((profileId: profileId, first: month, last: last)),
      )
      .whenData(
        (days) => MonthHistory(
          month: month,
          days: days,
          adherencePercent: adherencePercent(days.expand((d) => d.doses)),
        ),
      );
});

/// Fully-taken days in a row up to today, of [profileId].
final adherenceStreakProvider = Provider.autoDispose
    .family<AsyncValue<int>, String?>((ref, profileId) {
  final zone = ref.watch(historyZoneProvider(profileId));
  final today = localDateOf(ref.watch(nowProvider), zone);
  final first = today.addDays(-streakLookbackDays);
  return ref
      .watch(dayRangeProvider((profileId: profileId, first: first, last: today)))
      .whenData((days) => adherenceStreak(days, today));
});
