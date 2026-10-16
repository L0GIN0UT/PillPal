import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal_core/pillpal_core.dart';

// Statuses of the Today and History screens follow the dose-state contract
// (docs/spec/dose-state.md §5): a snoozed dose is due at its snooze_until,
// so it is not missed before snooze_until plus the grace.

// Daily 08:00 in Europe/Samara (UTC+4): the occurrence is 04:00Z.
const String _key = 's1/2026-10-17T08:00';

const MedicationRow _medication = MedicationRow(
  id: 'm',
  profileId: 'p',
  name: 'Med',
  tzMode: 'local',
  privacy: 'shared',
  clientUpdatedAt: 1,
  updatedByDevice: 'd',
);

const ScheduleRow _scheduleRow = ScheduleRow(
  id: 's1',
  medicationId: 'm',
  rule: '{}',
  clientUpdatedAt: 1,
  updatedByDevice: 'd',
);

final ParsedSchedule _schedule = ParsedSchedule(
  _scheduleRow,
  ScheduleRule.fromJson({
    'v': 1,
    'kind': 'daily',
    'start_date': '2026-10-01',
    'end_date': null,
    'times': [
      {
        'time': '08:00',
        'dose': {'amount': '1', 'unit': 'tablet'},
      },
    ],
  }),
);

DateTime _at(int minute) => DateTime.utc(2026, 10, 17, 4, minute);

DateTime _justBefore(DateTime moment) =>
    moment.subtract(const Duration(microseconds: 1));

DoseEventRow _row(
  String id,
  String type,
  int minute, {
  String? target,
  int? snoozeUntilMinute,
}) {
  return DoseEventRow(
    id: id,
    profileId: 'p',
    medicationId: 'm',
    eventType: type,
    at: _at(minute).microsecondsSinceEpoch,
    occurrenceKey: _key,
    targetEventId: target,
    snoozeUntil: snoozeUntilMinute == null
        ? null
        : _at(snoozeUntilMinute).microsecondsSinceEpoch,
  );
}

ScheduledDose _dose(List<DoseEventRow> events, DateTime now) {
  final doses = buildScheduledDoses(
    medications: [_medication],
    schedules: [_schedule],
    events: events,
    deviceTz: 'Europe/Samara',
    start: DateTime.utc(2026, 10, 17),
    end: DateTime.utc(2026, 10, 18),
    now: now,
  );
  expect(doses, hasLength(1));
  return doses.single;
}

void main() {
  final snoozed = _row('s1', 'snoozed', 5, snoozeUntilMinute: 20);

  test('an unsnoozed dose is missed from its time plus the grace', () {
    expect(_dose([], _justBefore(_at(30))).status, DoseStatus.pending);
    expect(_dose([], _at(30)).status, DoseStatus.missed);
  });

  test('a snoozed dose is not missed before snooze_until plus the grace', () {
    // Snoozed until 04:20: due 04:20, missed from 04:50 (not from 04:30).
    expect(_dose([snoozed], _at(30)).status, DoseStatus.pending);
    final justBefore = _justBefore(_at(50));
    expect(_dose([snoozed], justBefore).status, DoseStatus.pending);
    expect(_dose([snoozed], _at(50)).status, DoseStatus.missed);
  });

  test('a snooze that ends before the dose does not make it due earlier', () {
    // Minutes before 04:00 count back: snoozed at 03:50 until 03:55.
    final early = _row('s2', 'snoozed', -10, snoozeUntilMinute: -5);
    final before = DateTime.utc(2026, 10, 17, 3, 59);
    final edge = _at(30);
    expect(_dose([early], before).status, DoseStatus.pending);
    expect(_dose([early], edge).status, DoseStatus.missed);
  });

  test('an undone snooze leaves the dose due at its time', () {
    final undo = _row('u', 'undo', 6, target: 's1');
    expect(_dose([snoozed, undo], _at(30)).status, DoseStatus.missed);
  });

  test('a mark wins over a snooze whatever the time', () {
    final taken = _row('t', 'taken', 10);
    final dose = _dose([snoozed, taken], _at(59));
    expect(dose.status, DoseStatus.taken);
    expect(dose.mark?.eventId, 't');
  });
}
