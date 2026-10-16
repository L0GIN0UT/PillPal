import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

import 'support.dart';

const String other = '00000000-0000-4000-8000-000000000001';

AppliedNotification applied(
  NotificationRequest request, {
  String schedule = 'v1',
}) {
  return AppliedNotification(
    request,
    displayFingerprint: 'display',
    scheduleFingerprint: schedule,
  );
}

/// Every request a persistent plan made at 03:00Z, i.e. including the whole
/// 08:00 series that is in the past (delivered or delayed) at [now].
List<AppliedNotification> retainedPlan() {
  final result = plan(
    [source(level: ReminderLevel.persistent)],
    at: utc(16, 3),
  );
  return [for (final r in result.requests) applied(r)];
}

List<int> idsOf(
  Iterable<AppliedNotification> retained,
  bool Function(NotificationRequest) where,
) {
  return [
    for (final a in retained)
      if (where(a.request)) a.id,
  ]..sort();
}

List<int> settle(
  List<AppliedNotification> retained, {
  Set<String> handled = const <String>{},
  Set<String> snoozed = const <String>{},
  Map<String, String> live = const {sid: 'v1'},
}) {
  return settleIds(
    retained: retained,
    handledKeys: handled,
    snoozedKeys: snoozed,
    liveSchedules: live,
  );
}

void main() {
  final morning = key('2026-10-16', '08:00');

  test('nothing to settle', () {
    expect(settle(retainedPlan()), isEmpty);
  });

  test('a handled occurrence settles all its ids, past and future', () {
    final retained = retainedPlan();
    final ids = settle(retained, handled: {morning});
    expect(ids, idsOf(retained, (r) => r.occurrenceKey == morning));
    expect(ids, hasLength(4));
    final past = retained.where((a) => !a.request.fireAtUtc.isAfter(now));
    expect(past.map((a) => a.id).every(ids.contains), isTrue);
  });

  test('a handled occurrence also settles its snooze series', () {
    final snoozedPlan = plan(
      [source(level: ReminderLevel.persistent)],
      snoozed: {morning: utc(16, 5, 15)},
    );
    final retained = [
      for (final r in snoozedPlan.requests)
        if (r.isSnooze) applied(r),
    ];
    expect(retained, hasLength(4));
    expect(settle(retained, handled: {morning}), hasLength(4));
  });

  test('a snooze settles the regular series only', () {
    final snoozedPlan = plan(
      [source(level: ReminderLevel.persistent)],
      snoozed: {morning: utc(16, 5, 15)},
    );
    final retained = [
      ...retainedPlan(),
      for (final r in snoozedPlan.requests)
        if (r.isSnooze) applied(r),
    ];
    final ids = settle(retained, snoozed: {morning});
    expect(
      ids,
      idsOf(retained, (r) => r.occurrenceKey == morning && !r.isSnooze),
    );
  });

  test('a deleted or disabled schedule settles all its ids', () {
    final retained = retainedPlan();
    final ids = settle(retained, live: const {other: 'v1'});
    expect(ids, idsOf(retained, (r) => true));
  });

  test('a changed schedule fingerprint settles all its ids', () {
    final retained = retainedPlan();
    final all = idsOf(retained, (r) => true);
    expect(settle(retained, live: const {sid: 'v2'}), all);
    final mixed = [
      ...retained,
      applied(
        plan([source(scheduleId: other)]).requests.first,
        schedule: 'w1',
      ),
    ];
    final ids = settle(mixed, live: const {sid: 'v2', other: 'w1'});
    expect(ids, all);
  });

  test('ids are unique and ascending', () {
    final retained = [...retainedPlan(), ...retainedPlan()];
    final ids = settle(retained, handled: {morning});
    expect(ids, hasLength(4));
    expect(ids, [...ids]..sort());
  });
}
