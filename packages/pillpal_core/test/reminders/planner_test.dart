import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

import 'support.dart';

String scheduleIdFor(int i) =>
    '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}';

void main() {
  group('levels', () {
    test('normal: one notification per future occurrence', () {
      final result = plan([source()]);
      expect(fires(result), [
        (key('2026-10-16', '20:00'), 0, utc(16, 16)),
        (key('2026-10-17', '08:00'), 0, utc(17, 4)),
        (key('2026-10-17', '20:00'), 0, utc(17, 16)),
        (key('2026-10-18', '08:00'), 0, utc(18, 4)),
      ]);
      expect(result.replanBefore, utc(18, 5));
      expect(result.droppedByBudget, 0);
      expect(result.unplannableScheduleIds, isEmpty);
    });

    test('request fields', () {
      final first = plan([source()]).requests.first;
      final key0 = key('2026-10-16', '20:00');
      expect(first.id, baseNotificationId('$key0#0'));
      expect(first.occurrenceKey, key0);
      expect(first.medicationId, mid);
      expect(first.scheduleId, sid);
      expect(first.fireAtUtc.isUtc, isTrue);
      expect(first.repeatIndex, 0);
      expect(first.level, ReminderLevel.normal);
      expect(first.isSnooze, isFalse);
    });

    test('quiet ignores repeat settings', () {
      final quiet = plan([source(level: ReminderLevel.quiet, repeats: 5)]);
      final normal = plan([source()]);
      expect(fires(quiet), fires(normal));
      final levels = quiet.requests.map((r) => r.level).toSet();
      expect(levels, {ReminderLevel.quiet});
    });

    test('persistent repeats every N minutes, M times', () {
      final result = plan(
        [source(level: ReminderLevel.persistent)],
        horizon: const Duration(hours: 12),
      );
      // 08:00 (04:00Z) is past: only its repeat #3 at 05:30Z is still due.
      // The horizon ends at 17:00Z, exclusive.
      expect(fires(result), [
        (key('2026-10-16', '08:00'), 3, utc(16, 5, 30)),
        (key('2026-10-16', '20:00'), 0, utc(16, 16)),
        (key('2026-10-16', '20:00'), 1, utc(16, 16, 30)),
      ]);
      expect(result.replanBefore, utc(16, 17));
    });

    test('alarm repeats like persistent', () {
      final alarm = plan([source(level: ReminderLevel.alarm)]);
      final persistent = plan([source(level: ReminderLevel.persistent)]);
      expect(fires(alarm), fires(persistent));
      expect(alarm.requests.first.level, ReminderLevel.alarm);
    });

    test('maxRepeats 0 on a repeating level gives one notification', () {
      final result = plan([source(level: ReminderLevel.alarm, repeats: 0)]);
      expect(fires(result), fires(plan([source()])));
    });
  });

  group('fire-time filter', () {
    test('a fire time equal to now is not planned', () {
      final at = utc(16, 4);
      final normal = plan([source()], at: at);
      expect(normal.requests.first.fireAtUtc, utc(16, 16));
      final persistent = plan(
        [source(level: ReminderLevel.persistent, repeats: 1)],
        at: at,
      );
      expect(
        fires(persistent).first,
        (key('2026-10-16', '08:00'), 1, utc(16, 4, 30)),
      );
    });

    test('an occurrence older than its repeat span produces nothing', () {
      final result = plan(
        [source(level: ReminderLevel.persistent)],
        at: utc(16, 5, 30),
      );
      expect(result.requests.first.occurrenceKey, key('2026-10-16', '20:00'));
    });

    test('repeats stop before the next occurrence of the schedule', () {
      final rule = dailyRule(['08:00', '09:00']);
      final result = plan(
        [source(rule: rule, level: ReminderLevel.persistent, every: 20)],
        at: utc(16, 3),
        horizon: const Duration(hours: 3),
      );
      expect(fires(result), [
        (key('2026-10-16', '08:00'), 0, utc(16, 4)),
        (key('2026-10-16', '08:00'), 1, utc(16, 4, 20)),
        (key('2026-10-16', '08:00'), 2, utc(16, 4, 40)),
        (key('2026-10-16', '09:00'), 0, utc(16, 5)),
        (key('2026-10-16', '09:00'), 1, utc(16, 5, 20)),
        (key('2026-10-16', '09:00'), 2, utc(16, 5, 40)),
      ]);
    });
  });

  group('sources', () {
    test('handled occurrences produce nothing', () {
      final handled = {key('2026-10-16', '08:00'), key('2026-10-16', '20:00')};
      final result = plan(
        [source(level: ReminderLevel.persistent)],
        handled: handled,
      );
      expect(
        result.requests.where((r) => handled.contains(r.occurrenceKey)),
        isEmpty,
      );
      expect(result.requests.first.fireAtUtc, utc(17, 4));
    });

    test('disabled sources are ignored', () {
      final result = plan([source(enabled: false)]);
      expect(result.requests, isEmpty);
      expect(result.replanBefore, utc(18, 5));
    });

    test('as_needed schedules produce nothing', () {
      final rule = ScheduleRule.fromJson(<String, Object?>{
        'v': 1,
        'kind': 'as_needed',
        'start_date': '2026-10-01',
        'times': <Object?>[],
      });
      expect(plan([source(rule: rule)]).requests, isEmpty);
    });

    test('the course end bounds the plan', () {
      final rule = ScheduleRule.fromJson(<String, Object?>{
        'v': 1,
        'kind': 'daily',
        'start_date': '2026-10-01',
        'end_date': '2026-10-16',
        'times': [
          {
            'time': '20:00',
            'dose': {'amount': '1', 'unit': 'tablet'},
          },
        ],
      });
      expect(fires(plan([source(rule: rule)])), [
        (key('2026-10-16', '20:00'), 0, utc(16, 16)),
      ]);
    });

    test('several sources are merged by fire time, then key', () {
      const other = '00000000-0000-4000-8000-000000000001';
      final result = plan([
        source(),
        source(scheduleId: other, rule: dailyRule(['20:00'])),
      ]);
      expect(fires(result).take(3).toList(), [
        (key('2026-10-16', '20:00', scheduleId: other), 0, utc(16, 16)),
        (key('2026-10-16', '20:00'), 0, utc(16, 16)),
        (key('2026-10-17', '08:00'), 0, utc(17, 4)),
      ]);
    });

    test('same input gives the same plan regardless of source order', () {
      const other = '00000000-0000-4000-8000-000000000001';
      final a = source(level: ReminderLevel.persistent);
      final b = source(scheduleId: other, rule: dailyRule(['07:45', '20:00']));
      final snoozed = {key('2026-10-16', '08:00'): utc(16, 6)};
      final first = plan([a, b], snoozed: snoozed, budget: 9);
      final second = plan([b, a], snoozed: snoozed, budget: 9);
      expect(second.requests, first.requests);
      expect(second.replanBefore, first.replanBefore);
    });
  });

  group('caller errors', () {
    test('duplicate schedule ids', () {
      expect(() => plan([source(), source()]), throwsArgumentError);
    });

    test('budget out of range', () {
      expect(() => plan([source()], budget: -1), throwsArgumentError);
      expect(() => plan([source()], budget: 4, idMask: 3), throwsArgumentError);
    });

    test('horizon out of range', () {
      expect(
        () => plan([source()], horizon: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => plan([source()], horizon: const Duration(days: 30, seconds: 1)),
        throwsArgumentError,
      );
      expect(
        plan([source()], horizon: maxReminderHorizon).requests,
        hasLength(60),
      );
    });
  });

  test('hundreds of medications over 48 hours stay fast', () {
    final rule = dailyRule(['08:00', '12:00', '16:00', '20:00']);
    final sources = [
      for (var i = 0; i < 300; i++)
        source(
          scheduleId: scheduleIdFor(i),
          rule: rule,
          level: ReminderLevel.persistent,
          every: 15,
          repeats: 8,
        ),
    ];
    final stopwatch = Stopwatch()..start();
    final result = plan(sources);
    stopwatch.stop();
    expect(result.requests, hasLength(androidDefaultNotificationBudget));
    expect(result.droppedByBudget, greaterThan(0));
    // Generous bound for slow CI runners; typical runtime is far lower.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
  });
}
