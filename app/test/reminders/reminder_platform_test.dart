import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/reminders/device_platform.dart';
import 'package:pillpal/src/reminders/notification_scheduler.dart';
import 'package:pillpal/src/reminders/reminder_settings.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'reminder_test_env.dart';

// now = 2026-10-16T09:00Z (13:00 in Europe/Samara, UTC+4). The seeded
// schedule is daily at 08:00 local = 04:00Z, so the 48 h horizon holds the
// doses of Oct 17 and Oct 18.
final _oct17 = DateTime.utc(2026, 10, 17, 4);
final _oct18 = DateTime.utc(2026, 10, 18, 4);

void main() {
  late ReminderTestEnv env;

  setUp(() async => env = await ReminderTestEnv.create());
  tearDown(() => env.dispose());

  test('exact alarms: inexact when denied, upgraded when granted', () async {
    await env.seed();
    env.scheduler.grants = const ReminderPermissions(
      notificationsEnabled: true,
      exactAlarmsAllowed: false,
    );
    final denied = await env.service.replan();
    expect(denied.exactAlarms, isFalse);
    expect(
        env.scheduler.pending.values.map((r) => r.exact), everyElement(false));
    final ids = env.scheduler.pending.keys.toSet();
    env.scheduler.clearLog();

    env.scheduler.grants = ReminderPermissions.unknown;
    await env.service.replan();

    expect(env.scheduler.cancelled.toSet(), ids);
    expect(env.scheduler.scheduled.map((r) => r.id).toSet(), ids);
    expect(
        env.scheduler.pending.values.map((r) => r.exact), everyElement(true));
  });

  test('Time Sensitive off degrades only plans with repeating levels',
      () async {
    final ids = await env.seed();
    env.scheduler.grants = const ReminderPermissions(
      notificationsEnabled: true,
      exactAlarmsAllowed: true,
      timeSensitiveAllowed: false,
    );
    expect((await env.service.replan()).timeSensitiveDegraded, isFalse);

    await env.settings.setOverride(
      ids.medication,
      ReminderSettings(level: ReminderLevel.persistent),
    );
    final status = await env.service.replan();

    expect(status.timeSensitiveDegraded, isTrue);
    expect(status.permissions.timeSensitiveAllowed, isFalse);
  });

  test('time sensitive setting names map to allowed / not / unknown', () {
    expect(timeSensitiveFromSetting('enabled'), isTrue);
    expect(timeSensitiveFromSetting('disabled'), isFalse);
    expect(timeSensitiveFromSetting('notSupported'), isNull);
    expect(timeSensitiveFromSetting(null), isNull);
  });

  test('a refused exact alarm re-applies the plan inexact', () async {
    await env.seed();
    env.scheduler.refuseExact = true;

    final status = await env.service.replan();

    expect(status.exactAlarms, isFalse);
    expect(env.scheduler.pending, hasLength(2));
    expect(
        env.scheduler.pending.values.map((r) => r.exact), everyElement(false));
  });

  test('pending list check: lost reminders return, strays are cancelled',
      () async {
    await env.seed();
    await env.service.replan();
    final lost = env.scheduler.byTime.first;
    env.scheduler.pending.remove(lost.id); // e.g. dropped on boot
    const stray = 12345;
    env.scheduler.pending[stray] = lost;
    env.scheduler.pending[firstAppNotificationId] = lost; // not ours
    env.scheduler.clearLog();

    await env.service.replan();

    expect(env.scheduler.cancelled, [stray]);
    expect(env.scheduler.scheduled.map((r) => r.id), [lost.id]);
    expect(env.scheduler.pending.containsKey(firstAppNotificationId), isTrue);
  });

  test('Android: a new process re-arms every future reminder once', () async {
    await env.seed();
    await env.service.replan();
    final armed = env.scheduler.pending.keys.toSet();
    env.scheduler.forceStop();
    env.scheduler.clearLog();

    // Same process: the cache says pending, nothing is noticed.
    await env.service.replan();
    expect(env.scheduler.calls, isEmpty);

    final restarted = env.newService(rearmOnFirstReplan: true);
    addTearDown(restarted.dispose);
    await restarted.replan();

    expect(env.scheduler.scheduled.map((r) => r.id).toSet(), armed);
    expect(env.scheduler.cancelled, isEmpty);
    expect(env.scheduler.lostAlarms, isEmpty);
    env.scheduler.clearLog();

    await restarted.replan();
    expect(env.scheduler.calls, isEmpty);
  });

  test('iOS: a new process trusts the pending list', () async {
    await env.seed();
    await env.service.replan();
    env.scheduler.clearLog();

    final restarted = env.newService();
    addTearDown(restarted.dispose);
    await restarted.replan();

    expect(env.scheduler.calls, isEmpty);
  });

  test('one refused notification does not stop the others', () async {
    await env.seed();
    env.scheduler.failNextSchedules = 1;

    final failed = await env.service.replan();

    expect(failed.failed, isTrue);
    expect(env.scheduler.byTime.map((r) => r.fireAtUtc), [_oct18]);
    final db = env.data.db;
    expect(await db.select(db.appliedNotifications).get(), hasLength(1));

    final retried = await env.service.replan();

    expect(retried.failed, isFalse);
    expect(env.scheduler.byTime.map((r) => r.fireAtUtc), [_oct17, _oct18]);
    expect(await db.select(db.appliedNotifications).get(), hasLength(2));
  });
}
