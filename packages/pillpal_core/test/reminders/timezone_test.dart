import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

import 'support.dart';

const String other = '00000000-0000-4000-8000-000000000001';

Map<String, NotificationRequest> byKey(ReminderPlan plan) => {
      for (final request in plan.requests) request.occurrenceKey: request,
    };

void main() {
  group('device zone change', () {
    test('local sources follow the device zone, keys and ids stay', () {
      final samaraPlan = byKey(plan([source()]));
      final tokyoPlan = byKey(plan([source()], deviceTz: 'Asia/Tokyo'));
      expect(tokyoPlan.keys, unorderedEquals(samaraPlan.keys));
      for (final entry in samaraPlan.entries) {
        final moved = tokyoPlan[entry.key]!;
        expect(moved.id, entry.value.id);
        expect(
          entry.value.fireAtUtc.difference(moved.fireAtUtc),
          const Duration(hours: 5),
        );
      }
    });

    test('fixed sources stay in their zone', () {
      final fixed = source(tzMode: TzMode.fixed, fixedTz: samara);
      final inTokyo = plan([fixed], deviceTz: 'Asia/Tokyo');
      expect(inTokyo.requests, plan([source()]).requests);
    });
  });

  group('unknown zones', () {
    test('an unknown fixed zone is reported, others are planned', () {
      final broken = source(
        scheduleId: other,
        tzMode: TzMode.fixed,
        fixedTz: 'Mars/Olympus',
      );
      final result = plan([source(), broken]);
      expect(result.unplannableScheduleIds, [other]);
      expect(result.requests, plan([source()]).requests);
    });

    test('an unknown device zone affects only local sources', () {
      final fixed = source(
        scheduleId: other,
        tzMode: TzMode.fixed,
        fixedTz: samara,
      );
      final result = plan([source(), fixed], deviceTz: 'Nowhere/City');
      expect(result.unplannableScheduleIds, [sid]);
      expect(result.requests.map((r) => r.scheduleId).toSet(), {other});
    });

    test('unplannable schedule ids are sorted', () {
      final result = plan(
        [source(), source(scheduleId: other)],
        deviceTz: 'Nowhere/City',
      );
      expect(result.unplannableScheduleIds, [other, sid]);
    });
  });

  group('DST', () {
    test('Berlin gap: two keys at one instant, the earlier loses repeats', () {
      final rule = dailyRule(['02:30', '03:30'], startDate: '2026-03-01');
      final result = plan(
        [source(rule: rule, level: ReminderLevel.persistent, every: 15)],
        deviceTz: 'Europe/Berlin',
        at: DateTime.utc(2026, 3, 29),
        horizon: const Duration(hours: 2),
      );
      expect(fires(result), [
        (key('2026-03-29', '02:30'), 0, DateTime.utc(2026, 3, 29, 1, 30)),
        (key('2026-03-29', '03:30'), 0, DateTime.utc(2026, 3, 29, 1, 30)),
        (key('2026-03-29', '03:30'), 1, DateTime.utc(2026, 3, 29, 1, 45)),
      ]);
      final ids = result.requests.map((r) => r.id).toSet();
      expect(ids, hasLength(3));
    });

    test('Berlin overlap: repeats are spaced in elapsed time', () {
      final rule = dailyRule(['02:30']);
      final result = plan(
        [
          source(
            rule: rule,
            level: ReminderLevel.persistent,
            every: 60,
            repeats: 2,
          ),
        ],
        deviceTz: 'Europe/Berlin',
        at: DateTime.utc(2026, 10, 25),
        horizon: const Duration(hours: 6),
      );
      // 02:30 is ambiguous: the earlier instant (CEST) is used. The repeats
      // read 02:30 CET and 03:30 CET on the wall clock.
      expect(fires(result), [
        (key('2026-10-25', '02:30'), 0, DateTime.utc(2026, 10, 25, 0, 30)),
        (key('2026-10-25', '02:30'), 1, DateTime.utc(2026, 10, 25, 1, 30)),
        (key('2026-10-25', '02:30'), 2, DateTime.utc(2026, 10, 25, 2, 30)),
      ]);
    });

    test('New York gap: the wall time is read with the old offset', () {
      final rule = dailyRule(['02:15'], startDate: '2026-03-01');
      final result = plan(
        [source(rule: rule)],
        deviceTz: 'America/New_York',
        at: DateTime.utc(2026, 3, 8),
        horizon: const Duration(hours: 12),
      );
      expect(fires(result), [
        (key('2026-03-08', '02:15'), 0, DateTime.utc(2026, 3, 8, 7, 15)),
      ]);
    });
  });
}
