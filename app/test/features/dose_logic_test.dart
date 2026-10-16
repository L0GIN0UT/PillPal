import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal_core/pillpal_core.dart';

DoseEventRow _event(
  String id,
  String type,
  int minute, {
  String? target,
  String? key = 'k',
}) =>
    DoseEventRow(
      id: id,
      profileId: 'p',
      medicationId: 'm',
      eventType: type,
      at: DateTime.utc(2026, 10, 16, 8, minute).microsecondsSinceEpoch,
      occurrenceKey: key,
      targetEventId: target,
    );

ScheduleRule _rule(Map<String, Object?> extra) => ScheduleRule.fromJson({
      'v': 1,
      'start_date': '2026-10-01',
      'end_date': null,
      'times': [
        {
          'time': '08:00',
          'dose': {'amount': '2', 'unit': 'tablet'},
        },
      ],
      ...extra,
    });

void main() {
  group('local time', () {
    test('wall clock and day bounds in a fixed-offset zone', () {
      final wall = wallClockOf(DateTime.utc(2026, 10, 16, 21, 30), testZone);
      expect(wall.date, LocalDate(2026, 10, 17));
      expect(wall.hhmm, '01:30');
      final bounds = dayBounds(LocalDate(2026, 10, 16), testZone);
      expect(bounds.start, DateTime.utc(2026, 10, 15, 20));
      expect(bounds.end, DateTime.utc(2026, 10, 16, 20));
    });

    test('wall clock across a DST change', () {
      // Berlin: CEST (+2) until 2026-10-25 03:00, then CET (+1).
      expect(
        wallClockOf(DateTime.utc(2026, 10, 24, 10), 'Europe/Berlin').hhmm,
        '12:00',
      );
      expect(
        wallClockOf(DateTime.utc(2026, 10, 26, 10), 'Europe/Berlin').hhmm,
        '11:00',
      );
    });

    test('device zone guess falls back to a known zone', () {
      expect(isKnownTimeZone('Europe/Moscow'), isTrue);
      expect(isKnownTimeZone('Mars/Base'), isFalse);
      expect(isKnownTimeZone(guessDeviceTimeZone(DateTime.now())), isTrue);
      expect(nextMonthStart(LocalDate(2026, 12, 5)), LocalDate(2027, 1, 1));
      expect(previousMonthStart(LocalDate(2026, 1, 5)), LocalDate(2025, 12, 1));
    });
  });

  group('dose status', () {
    final due = DateTime.utc(2026, 10, 16, 8);

    test('pending, then missed after the grace period', () {
      expect(doseStatus(null, due, due), DoseStatus.pending);
      expect(
        doseStatus(null, due, due.add(const Duration(minutes: 31))),
        DoseStatus.missed,
      );
    });

    test('the latest mark not undone wins', () {
      final events = [
        _event('a', 'taken', 1),
        _event('b', 'skipped', 2),
        _event('c', 'undo', 3, target: 'b'),
        _event('d', 'snoozed', 4),
      ];
      final mark = effectiveMark(events);
      expect(mark?.eventId, 'a');
      expect(doseStatus(mark, due, due), DoseStatus.taken);

      final undone = [...events, _event('e', 'undo', 5, target: 'a')];
      expect(effectiveMark(undone), isNull);
      expect(eventsByOccurrence(undone)['k'], hasLength(5));
    });

    test('equal instants are decided by the larger id on every device', () {
      final taken = _event('a', 'taken', 1);
      final skipped = _event('b', 'skipped', 1);
      expect(effectiveMark([taken, skipped])?.eventId, 'b');
      expect(effectiveMark([skipped, taken])?.eventId, 'b');
    });
  });

  group('schedule state (ADR 0003)', () {
    final today = LocalDate(2026, 10, 16);
    final running = _rule({'kind': 'daily'});
    final ended = _rule({'kind': 'daily', 'end_date': '2026-10-15'});
    final future = _rule({'kind': 'daily', 'start_date': '2026-10-20'});

    test('running, ended and history', () {
      expect(isRunningOn(running, today), isTrue);
      expect(isRunningOn(ended, today), isFalse);
      expect(isRunningOn(future, today), isFalse);
      expect(hasEndedBy(ended, today), isTrue);
      expect(hasEndedBy(running, today), isFalse);
      expect(hasHistoryBefore(running, today), isTrue);
      expect(hasHistoryBefore(future, today), isFalse);
    });

    test('archived only with schedules, all of them ended', () {
      expect(isArchivedOn([ended], today), isTrue);
      expect(isArchivedOn([ended, running], today), isFalse);
      expect(isArchivedOn(const [], today), isFalse);
    });
  });
}

const String testZone = 'Europe/Samara';
