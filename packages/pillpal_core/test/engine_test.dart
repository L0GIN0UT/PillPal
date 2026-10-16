import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

const String sid = '7f1c2d3e-0000-4000-8000-0000000000e2';

final ScheduleRule daily = ScheduleRule.fromJson(<String, Object?>{
  'v': 1,
  'kind': 'daily',
  'start_date': '2026-10-01',
  'times': [
    {'time': '20:00', 'dose': {'amount': '0.5', 'unit': 'tablet'}},
    {'time': '08:00', 'dose': {'amount': '1', 'unit': 'tablet'}},
  ],
});

final DateTime t0 = DateTime.utc(2026, 10, 16);

List<Occurrence> expandDaily(String tz, DateTime start, DateTime end) {
  return expand(daily, scheduleId: sid, tz: tz, start: start, end: end);
}

void main() {
  test('occurrenceKey uses the nominal local date and time', () {
    final key = occurrenceKey(sid, LocalDate(2026, 10, 16), '08:00');
    expect(key, '$sid/2026-10-16T08:00');
  });

  test('occurrence fields', () {
    final day = t0.add(const Duration(days: 1));
    final first = expandDaily('Europe/Samara', t0, day).first;
    expect(first.key, '$sid/2026-10-16T08:00');
    expect(first.localDate, LocalDate(2026, 10, 16));
    expect(first.localTime, '08:00');
    expect(first.atUtc, DateTime.utc(2026, 10, 16, 4));
    expect(first.atUtc.isUtc, isTrue);
    expect(first.doseAmount, '1');
    expect(first.doseUnit, 'tablet');
  });

  test('window bounds are compared as instants', () {
    final end = t0.add(const Duration(days: 2));
    final utc = expandDaily('Asia/Kolkata', t0, end);
    final local = expandDaily('Asia/Kolkata', t0.toLocal(), end.toLocal());
    expect(local, equals(utc));
    expect(utc, hasLength(4));
  });

  test('result is sorted by instant, then key', () {
    final end = t0.add(const Duration(days: 5));
    final occurrences = expandDaily('Asia/Kathmandu', t0, end);
    expect(occurrences, hasLength(10));
    for (var i = 1; i < occurrences.length; i++) {
      final previous = occurrences[i - 1].atUtc;
      expect(occurrences[i].atUtc.isBefore(previous), isFalse);
    }
  });

  test('same rule in two zones: same keys, different instants', () {
    final end = t0.add(const Duration(days: 3));
    final samara = expandDaily('Europe/Samara', t0, end);
    final tokyo = expandDaily('Asia/Tokyo', t0, end);
    final tokyoByKey = {for (final o in tokyo) o.key: o.atUtc};
    var shared = 0;
    for (final occurrence in samara) {
      final other = tokyoByKey[occurrence.key];
      if (other != null) {
        shared++;
        expect(occurrence.atUtc.difference(other), const Duration(hours: 5));
      }
    }
    expect(shared, greaterThan(0));
  });

  test('exactly 400 days and an empty window are allowed', () {
    final end = t0.add(const Duration(days: 400));
    expect(expandDaily('UTC', t0, end), hasLength(800));
    expect(expandDaily('UTC', t0, t0), isEmpty);
  });

  group('caller errors', () {
    final end = t0.add(const Duration(days: 1));

    test('empty schedule id', () {
      expect(
        () => expand(daily, scheduleId: '', tz: 'UTC', start: t0, end: end),
        throwsArgumentError,
      );
    });

    test('end before start', () {
      final before = t0.subtract(const Duration(seconds: 1));
      expect(() => expandDaily('UTC', t0, before), throwsArgumentError);
    });

    test('window longer than 400 days', () {
      final tooLate = t0.add(const Duration(days: 400, seconds: 1));
      expect(() => expandDaily('UTC', t0, tooLate), throwsArgumentError);
    });

    test('unknown time zone', () {
      expect(() => expandDaily('Mars/Olympus', t0, end), throwsArgumentError);
      expect(() => expandDaily('', t0, end), throwsArgumentError);
    });
  });

  group('localToUtc', () {
    test('normal time', () {
      final at = localToUtc(LocalDate(2026, 7, 1), 8, 0, 'Europe/Berlin');
      expect(at, DateTime.utc(2026, 7, 1, 6));
    });

    test('gap: wall time minus the pre-transition offset', () {
      final day = LocalDate(2026, 3, 29);
      expect(
        localToUtc(day, 2, 30, 'Europe/Berlin'),
        DateTime.utc(2026, 3, 29, 1, 30),
      );
      expect(
        localToUtc(LocalDate(2026, 3, 8), 2, 15, 'America/New_York'),
        DateTime.utc(2026, 3, 8, 7, 15),
      );
    });

    test('overlap: the earlier instant', () {
      expect(
        localToUtc(LocalDate(2026, 10, 25), 2, 30, 'Europe/Berlin'),
        DateTime.utc(2026, 10, 25, 0, 30),
      );
      expect(
        localToUtc(LocalDate(2026, 11, 1), 1, 30, 'America/New_York'),
        DateTime.utc(2026, 11, 1, 5, 30),
      );
    });

    test('skipped calendar day in Pacific/Apia', () {
      expect(
        localToUtc(LocalDate(2011, 12, 30), 8, 0, 'Pacific/Apia'),
        DateTime.utc(2011, 12, 30, 18),
      );
    });

    test('UTC is always available', () {
      final at = localToUtc(LocalDate(2026, 10, 16), 23, 59, 'UTC');
      expect(at, DateTime.utc(2026, 10, 16, 23, 59));
      expect(at.isUtc, isTrue);
    });
  });
}
