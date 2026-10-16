import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/features/doses/stock.dart';
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

MedicationRow _medication({String? stock, int? lowDays}) => MedicationRow(
      id: 'm',
      profileId: 'p',
      name: 'Med',
      tzMode: 'local',
      privacy: 'shared',
      clientUpdatedAt: 1,
      updatedByDevice: 'd',
      stockCount: stock,
      lowStockDays: lowDays,
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
  });

  group('stock', () {
    final today = LocalDate(2026, 10, 16);

    test('daily consumption per rule kind', () {
      expect(dailyConsumption(_rule({'kind': 'daily'})), 2);
      expect(
        dailyConsumption(_rule({'kind': 'interval_days', 'interval_days': 4})),
        0.5,
      );
      expect(
        dailyConsumption(_rule({
          'kind': 'weekdays',
          'weekdays': [1, 2, 3, 4, 5, 6, 7],
        })),
        2,
      );
    });

    test('days left and the low-stock threshold', () {
      final rules = [
        _rule({'kind': 'daily'})
      ];
      expect(stockDaysLeft(_medication(), rules, today), isNull);
      final low = _medication(stock: '9');
      expect(stockDaysLeft(low, rules, today), 4);
      expect(isLowStock(low, 4), isTrue);
      expect(isLowStock(_medication(stock: '9', lowDays: 3), 4), isFalse);
    });
  });
}

const String testZone = 'Europe/Samara';
