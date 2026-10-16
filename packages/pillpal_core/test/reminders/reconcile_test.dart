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

AppliedNotification applied(
  NotificationRequest request, {
  String display = 'exact|normal|shared|ru',
  String schedule = 'v1',
}) {
  return AppliedNotification(
    request,
    displayFingerprint: display,
    scheduleFingerprint: schedule,
  );
}

List<AppliedNotification> appliedAll(
  ReminderPlan plan, {
  String display = 'exact|normal|shared|ru',
}) {
  return [for (final r in plan.requests) applied(r, display: display)];
}

void main() {
  test('cancel removed ids, schedule new and changed requests', () {
    final previous = [
      applied(request(1, utc(16, 6))),
      applied(request(2, utc(16, 7))),
    ];
    final next = [
      applied(request(2, utc(16, 8))),
      applied(request(3, utc(16, 9))),
    ];
    final diff = reconcile(previous, next, now: now);
    expect(diff.cancelIds, [1]);
    expect(diff.schedule, next);
    expect(diff.isEmpty, isFalse);
  });

  test('cancel ids are ascending; unchanged requests are left alone', () {
    final previous = [
      applied(request(9, utc(16, 9))),
      applied(request(5, utc(16, 6))),
      applied(request(7, utc(16, 7))),
    ];
    final diff = reconcile(
      previous,
      [applied(request(5, utc(16, 6)))],
      now: now,
    );
    expect(diff.cancelIds, [7, 9]);
    expect(diff.schedule, isEmpty);
  });

  test('applying the same plan twice is a no-op', () {
    final current = plan([source(level: ReminderLevel.persistent)]);
    final again = plan([source(level: ReminderLevel.persistent)]);
    final diff = reconcile(appliedAll(current), appliedAll(again), now: now);
    expect(diff.isEmpty, isTrue);
  });

  test('a display change cancels and reschedules under the same id', () {
    // E.g. exact alarms granted later, or the medication became hidden.
    final current = plan([source()]);
    final inexact = appliedAll(current, display: 'inexact|normal|shared|ru');
    final exact = appliedAll(current, display: 'exact|normal|hidden|ru');
    final diff = reconcile(inexact, exact, now: now);
    final ids = current.requests.map((r) => r.id).toList()..sort();
    expect(diff.cancelIds, ids);
    expect(diff.schedule, exact);
  });

  test('marking a dose cancels exactly its future notifications', () {
    final persistent = source(level: ReminderLevel.persistent);
    final before = plan([persistent]);
    final evening = key('2026-10-16', '20:00');
    final after = plan([persistent], handled: {evening});
    final diff = reconcile(appliedAll(before), appliedAll(after), now: now);
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
    final diff = reconcile(appliedAll(before), appliedAll(after), now: now);
    expect(diff.cancelIds, [baseNotificationId('$morning#3')]);
    final snoozes = diff.schedule.map((a) => a.request.isSnooze);
    expect(snoozes, [true, true, true, true]);
  });

  test('a device zone change reschedules in place', () {
    final before = plan([source()]);
    final after = plan([source()], deviceTz: 'Asia/Tokyo');
    final diff = reconcile(appliedAll(before), appliedAll(after), now: now);
    expect(diff.cancelIds, isEmpty);
    expect(diff.schedule, appliedAll(after));
  });

  test('past notifications are left to settleIds', () {
    final past = applied(request(1, now));
    final pending = applied(request(2, utc(16, 6)));
    final diff = reconcile([past, pending], [pending], now: now);
    expect(diff.isEmpty, isTrue);
    final changedDisplay = applied(request(1, now), display: 'other');
    expect(reconcile([past], [changedDisplay], now: now).cancelIds, isEmpty);
    final replaced = applied(request(1, utc(16, 7)));
    expect(reconcile([past], [replaced], now: now).schedule, [replaced]);
  });

  test('applied notifications have value equality', () {
    final a = applied(request(1, utc(16, 6)));
    expect(a, applied(request(1, utc(16, 6))));
    expect(a.hashCode, applied(request(1, utc(16, 6))).hashCode);
    expect(a, isNot(applied(request(1, utc(16, 6)), display: 'x')));
    expect(a, isNot(applied(request(1, utc(16, 6)), schedule: 'v2')));
    expect(a.id, 1);
  });
}
