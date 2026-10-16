import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

import 'support.dart';

NotificationRequest request(int id, DateTime fireAt) => NotificationRequest(
      id: id,
      occurrenceKey: key('2026-10-16', '08:00'),
      medicationId: mid,
      scheduleId: sid,
      fireAtUtc: fireAt,
      repeatIndex: 0,
      level: ReminderLevel.normal,
      isSnooze: false,
    );

void main() {
  test('cancel removed ids, schedule new and changed requests', () {
    final previous = [request(1, utc(16, 4)), request(2, utc(16, 5))];
    final next = [request(2, utc(16, 6)), request(3, utc(16, 7))];
    final diff = reconcile(previous, next);
    expect(diff.cancelIds, [1]);
    expect(diff.schedule, next);
    expect(diff.isEmpty, isFalse);
  });

  test('cancel ids are ascending; unchanged requests are left alone', () {
    final previous = [
      request(9, utc(16, 4)),
      request(5, utc(16, 5)),
      request(7, utc(16, 6)),
    ];
    final diff = reconcile(previous, [request(5, utc(16, 5))]);
    expect(diff.cancelIds, [7, 9]);
    expect(diff.schedule, isEmpty);
  });

  test('applying the same plan twice is a no-op', () {
    final current = plan([source(level: ReminderLevel.persistent)]);
    final again = plan([source(level: ReminderLevel.persistent)]);
    expect(reconcile(current.requests, again.requests).isEmpty, isTrue);
  });

  test('marking a dose cancels exactly its notifications', () {
    final persistent = source(level: ReminderLevel.persistent);
    final before = plan([persistent]);
    final evening = key('2026-10-16', '20:00');
    final after = plan([persistent], handled: {evening});
    final diff = reconcile(before.requests, after.requests);
    final expected = [
      for (final r in before.requests)
        if (r.occurrenceKey == evening) r.id,
    ]..sort();
    expect(diff.cancelIds, expected);
    expect(diff.cancelIds, hasLength(4));
    expect(diff.schedule, isEmpty);
  });

  test('a snooze swaps the regular series for the snooze series', () {
    final persistent = source(level: ReminderLevel.persistent);
    final morning = key('2026-10-16', '08:00');
    final before = plan([persistent]);
    final after = plan([persistent], snoozed: {morning: utc(16, 5, 15)});
    final diff = reconcile(before.requests, after.requests);
    expect(diff.cancelIds, [baseNotificationId('$morning#3')]);
    expect(diff.schedule.map((r) => r.isSnooze), [true, true, true, true]);
  });

  test('a device zone change reschedules in place', () {
    final before = plan([source()]);
    final after = plan([source()], deviceTz: 'Asia/Tokyo');
    final diff = reconcile(before.requests, after.requests);
    expect(diff.cancelIds, isEmpty);
    expect(diff.schedule, after.requests);
  });
}
