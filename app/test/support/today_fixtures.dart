import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal/src/features/stock/stock_level.dart';
import 'package:pillpal/src/features/today/today_state.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../helpers.dart';

/// Synthetic Today data shared by the Today tests: 2026-10-16, "now" is
/// 10:00 in [testZone] (06:00 UTC), one dose per state.

/// The schedule of every fixture dose.
const String fixtureSchedule = 'sched-1';

/// A shared medication named [name].
MedicationRow fixtureMedication(String id, String name) => MedicationRow(
      id: id,
      profileId: 'self',
      name: name,
      strengthText: '500 mg',
      tzMode: 'local',
      privacy: 'shared',
      redacted: false,
      gtinLinkShared: false,
      clientUpdatedAt: 1,
      updatedByDevice: 'd',
    );

/// Occurrence key of the dose at [time] (`HH:MM`).
String fixtureKey(String time) => '$fixtureSchedule/2026-10-16T$time';

/// A dose at [time] named `Med <time>` with [status].
ScheduledDose fixtureDose(String time, DoseStatus status) {
  final hour = int.parse(time.substring(0, 2));
  final minute = int.parse(time.substring(3));
  final marked = status == DoseStatus.taken || status == DoseStatus.skipped;
  return ScheduledDose(
    medication: fixtureMedication('med-$time', 'Med $time'),
    scheduleId: fixtureSchedule,
    occurrence: Occurrence(
      key: fixtureKey(time),
      localDate: LocalDate(2026, 10, 16),
      localTime: time,
      // Europe/Samara is UTC+4.
      atUtc: DateTime.utc(2026, 10, 16, hour - 4, minute),
      doseAmount: '1',
      doseUnit: 'tablet',
    ),
    status: status,
    mark: marked
        ? DoseMark(
            eventId: 'e-$time',
            type: status == DoseStatus.taken
                ? DoseEventType.taken
                : DoseEventType.skipped,
            at: DateTime.utc(2026, 10, 16, hour - 4, minute),
          )
        : null,
    zone: testZone,
    displayZone: testZone,
  );
}

/// A Today state of [doses] at 10:00.
TodayState fixtureState(
  List<ScheduledDose> doses, {
  List<LowStockMedication> lowStock = const [],
}) =>
    TodayState(
      date: LocalDate(2026, 10, 16),
      doses: doses,
      asNeeded: const [],
      lowStock: lowStock,
      hasMedications: true,
      now: DateTime.utc(2026, 10, 16, 6),
    );

/// The four doses of the matrix: taken 07:00, missed 08:00, snoozed (still
/// pending) 09:50, pending 20:00, and a low-stock medication.
TodayState fixtureDay() => fixtureState(
      [
        fixtureDose('07:00', DoseStatus.taken),
        fixtureDose('08:00', DoseStatus.missed),
        fixtureDose('09:50', DoseStatus.pending),
        fixtureDose('20:00', DoseStatus.pending),
      ],
      lowStock: [
        LowStockMedication(
          fixtureMedication('med-low', 'Med L'),
          const StockKnown(
            remainingMilli: 2000,
            unit: DoseUnit.tablet,
            daysLeft: 2,
          ),
        ),
      ],
    );
