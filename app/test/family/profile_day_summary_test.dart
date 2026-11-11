import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal/src/features/family/profile_day_summary.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../helpers.dart' show testZone;
import '../support/today_fixtures.dart';

// The per-profile summary of the Family tab (R9): pure counts over the day
// view's dose list. testZone is Europe/Samara (UTC+4); "now" is 10:00 there.

final DateTime _now = DateTime.utc(2026, 10, 16, 6);

ScheduledDose _dose(String time, DoseStatus status) =>
    fixtureDose(time, status);

/// A dose whose instant is [at] (UTC), whatever the fixture date says.
ScheduledDose _doseAt(DateTime at, DoseStatus status) {
  final base = fixtureDose('12:00', status);
  return ScheduledDose(
    medication: base.medication,
    scheduleId: base.scheduleId,
    occurrence: Occurrence(
      key: 'sched-1/${at.toIso8601String()}',
      localDate: base.occurrence.localDate,
      localTime: base.occurrence.localTime,
      atUtc: at,
      doseAmount: '1',
      doseUnit: 'tablet',
    ),
    status: status,
    mark: base.mark,
    zone: testZone,
    displayZone: testZone,
  );
}

ProfileDaySummary _summary(List<ScheduledDose> doses, {DateTime? now}) =>
    profileDaySummary(doses, now ?? _now, testZone);

void main() {
  group('profileDaySummary counts', () {
    test('an empty day has no doses and no next one', () {
      final summary = _summary(const []);

      expect(summary.total, 0);
      expect(summary.nextDue, isNull);
      expect(summary.kind, isNull);
    });

    test('counts every status; skipped is resolved but not taken', () {
      final summary = _summary([
        _dose('07:00', DoseStatus.taken),
        _dose('08:00', DoseStatus.missed),
        _dose('09:00', DoseStatus.skipped),
        _dose('20:00', DoseStatus.pending),
        _dose('21:00', DoseStatus.pending),
      ]);

      expect(summary.taken, 1);
      expect(summary.missed, 1);
      expect(summary.skipped, 1);
      expect(summary.pending, 2);
      expect(summary.total, 5);
    });

    test('the next dose is the earliest pending one still ahead', () {
      final summary = _summary([
        _dose('09:50', DoseStatus.pending), // due, within the grace
        _dose('21:00', DoseStatus.pending),
        _dose('20:00', DoseStatus.pending),
      ]);

      expect(summary.nextDue, DateTime.utc(2026, 10, 16, 16));
    });

    test('no next dose when everything left is missed or marked', () {
      final summary = _summary([
        _dose('08:00', DoseStatus.missed),
        _dose('09:00', DoseStatus.taken),
      ]);

      expect(summary.nextDue, isNull);
    });
  });

  group('profileDaySummary kind', () {
    test('all taken', () {
      final summary = _summary([
        _dose('07:00', DoseStatus.taken),
        _dose('08:00', DoseStatus.taken),
      ]);

      expect(summary.kind, DaySummaryKind.allTaken);
    });

    test('taken and skipped only still counts as done', () {
      final summary = _summary([
        _dose('07:00', DoseStatus.taken),
        _dose('08:00', DoseStatus.skipped),
      ]);

      expect(summary.kind, DaySummaryKind.allTaken);
    });

    test('only skipped doses say nothing', () {
      final summary = _summary([_dose('07:00', DoseStatus.skipped)]);

      expect(summary.kind, isNull);
    });

    test('any missed dose wins over pending and taken', () {
      final summary = _summary([
        _dose('07:00', DoseStatus.taken),
        _dose('08:00', DoseStatus.missed),
        _dose('20:00', DoseStatus.pending),
      ]);

      expect(summary.kind, DaySummaryKind.missed);
    });

    test('otherwise something is still waiting', () {
      final summary = _summary([
        _dose('07:00', DoseStatus.taken),
        _dose('20:00', DoseStatus.pending),
      ]);

      expect(summary.kind, DaySummaryKind.waiting);
    });
  });

  group('profileDaySummary day boundary', () {
    test('doses of other days in the profile zone are left out', () {
      // Samara midnight is 20:00 UTC: 19:59 UTC is still 23:59 on the 16th,
      // 20:00 UTC is already the 17th.
      final summary = _summary([
        _doseAt(DateTime.utc(2026, 10, 15, 19, 59), DoseStatus.taken),
        _doseAt(DateTime.utc(2026, 10, 15, 20), DoseStatus.taken),
        _doseAt(DateTime.utc(2026, 10, 16, 19, 59), DoseStatus.pending),
        _doseAt(DateTime.utc(2026, 10, 16, 20), DoseStatus.pending),
      ]);

      expect(summary.total, 2);
      expect(summary.taken, 1);
      expect(summary.pending, 1);
    });

    test('the day is the one of the profile zone, not UTC', () {
      // 21:00 UTC is 01:00 on the 17th in Samara; by UTC it is still the
      // 16th, and both doses would be counted.
      final late = DateTime.utc(2026, 10, 16, 21); // 01:00 on the 17th
      final summary = profileDaySummary(
        [
          _doseAt(late, DoseStatus.pending),
          _doseAt(DateTime.utc(2026, 10, 16, 18), DoseStatus.pending),
        ],
        late.add(const Duration(minutes: 5)),
        testZone,
      );

      // "Today" is the 17th there: only the 01:00 dose belongs to it.
      expect(summary.total, 1);
    });

    test('a DST fall-back day counts its doses once', () {
      // Europe/Berlin 2026-10-25 has 25 hours; both 02:30 readings are the
      // same dose in the engine, so the list has what it has.
      final start = DateTime.utc(2026, 10, 24, 22);
      final summary = profileDaySummary(
        [
          _doseAt(start, DoseStatus.taken),
          _doseAt(DateTime.utc(2026, 10, 25, 22, 59), DoseStatus.pending),
          _doseAt(DateTime.utc(2026, 10, 25, 23), DoseStatus.pending),
        ],
        DateTime.utc(2026, 10, 25, 5),
        'Europe/Berlin',
      );

      // The day ends at 23:00 UTC (25 hours long): 22:59 is in, 23:00 is not.
      expect(summary.total, 2);
    });
  });

  group('staleDataAge', () {
    final seven = _now.subtract(const Duration(hours: 7));
    final one = _now.subtract(const Duration(hours: 1));

    test('unknown times say nothing', () {
      expect(staleDataAge(now: _now), isNull);
    });

    test('is the age of the older sync once it passes the limit', () {
      expect(
        staleDataAge(now: _now, ownerLastSeenAt: seven, lastSyncAt: one),
        const Duration(hours: 7),
      );
      expect(
        staleDataAge(now: _now, ownerLastSeenAt: one, lastSyncAt: seven),
        const Duration(hours: 7),
      );
    });

    test('is null just below the limit and set exactly at it', () {
      final below = _now.subtract(staleDataAfter - const Duration(minutes: 1));
      final at = _now.subtract(staleDataAfter);

      expect(staleDataAge(now: _now, lastSyncAt: below), isNull);
      expect(staleDataAge(now: _now, lastSyncAt: at), staleDataAfter);
    });
  });
}
