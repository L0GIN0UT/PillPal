import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

import 'support.dart';

const String early = '00000000-0000-4000-8000-000000000001';
const String late = 'ffffffff-0000-4000-8000-000000000001';

List<ReminderSource> mixedSources() => [
      source(level: ReminderLevel.persistent),
      source(
        scheduleId: early,
        rule: dailyRule(['06:00', '08:00', '13:30', '20:00']),
        level: ReminderLevel.alarm,
        every: 20,
        repeats: 5,
      ),
      source(
        scheduleId: late,
        rule: dailyRule(['08:00', '21:15']),
        level: ReminderLevel.quiet,
      ),
    ];

void main() {
  test('the budget keeps the earliest notifications', () {
    final result = plan([source(level: ReminderLevel.persistent)], budget: 2);
    expect(fires(result), [
      (key('2026-10-16', '08:00'), 3, utc(16, 5, 30)),
      (key('2026-10-16', '20:00'), 0, utc(16, 16)),
    ]);
    expect(result.replanBefore, utc(16, 16, 30));
    expect(result.droppedByBudget, 13);
  });

  test('budget 0 plans nothing and asks to replan at the first fire', () {
    final result = plan([source(level: ReminderLevel.persistent)], budget: 0);
    expect(result.requests, isEmpty);
    expect(result.replanBefore, utc(16, 5, 30));
    expect(result.droppedByBudget, 15);
  });

  test('at the same instant a first notification beats a repeat', () {
    final nagging = source(
      scheduleId: early,
      rule: dailyRule(['08:00']),
      level: ReminderLevel.persistent,
      every: 60,
      repeats: 1,
    );
    final next = source(rule: dailyRule(['09:00']));
    final result = plan([nagging, next], at: utc(16, 4, 30), budget: 1);
    // Both fire at 05:00Z; the repeat's key sorts first, the tier wins.
    expect(fires(result), [(key('2026-10-16', '09:00'), 0, utc(16, 5))]);
    expect(result.replanBefore, utc(16, 5));
  });

  test('a smaller budget yields a prefix of the full plan', () {
    final full = plan(mixedSources());
    expect(full.droppedByBudget, 0);
    expect(full.requests.length, greaterThan(40));
    for (final budget in [0, 1, 5, 17, 40]) {
      final cut = plan(mixedSources(), budget: budget);
      expect(cut.requests, full.requests.take(budget).toList());
      expect(cut.replanBefore, full.requests[budget].fireAtUtc);
      expect(cut.droppedByBudget, full.requests.length - budget);
    }
  });

  test('no kept notification fires after a dropped one', () {
    final full = plan(mixedSources());
    final cut = plan(mixedSources(), budget: 23);
    final lastKept = cut.requests.last.fireAtUtc;
    for (final dropped in full.requests.skip(23)) {
      expect(dropped.fireAtUtc.isBefore(lastKept), isFalse);
      expect(dropped.fireAtUtc.isBefore(cut.replanBefore), isFalse);
    }
  });

  test('the iOS limit caps a large plan', () {
    final sources = [
      for (var i = 0; i < 30; i++)
        source(
          scheduleId: '00000000-0000-4000-8000-0000000000${10 + i}',
          rule: dailyRule(['08:00', '12:00', '16:00', '20:00']),
        ),
    ];
    final result = plan(sources, budget: iosPendingNotificationLimit);
    expect(result.requests, hasLength(64));
    expect(result.droppedByBudget, greaterThan(0));
  });
}
