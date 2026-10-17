import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';

import 'reminder_test_env.dart';

// What the service schedules for other scopes and in which zone (ADR 0006
// §6, decision D4), through the fake platform adapter. now = 2026-10-16
// 09:00Z unless a test moves the clock.

void main() {
  late ReminderTestEnv env;

  setUp(() async => env = await ReminderTestEnv.create());
  tearDown(() => env.dispose());

  Future<void> planned(String profile) async {
    await env.service.replan();
    expect(env.scheduler.pending, isNotEmpty, reason: profile);
  }

  test('evicting a scope cancels the reminders already scheduled', () async {
    final ids = await env.data.seedLocal();
    await planned(ids.profile);
    final scheduled = env.scheduler.pending.keys.toSet();
    env.scheduler.clearLog();

    await env.data.db.evictScope(ids.profile);
    await env.service.replan();

    expect(env.scheduler.pending, isEmpty);
    expect(env.scheduler.cancelled.toSet(), scheduled);
  });

  test('archiving a scope cancels its reminders, restoring brings them back',
      () async {
    final ids = await env.data.seedLocal();
    await planned(ids.profile);
    final scheduled = env.scheduler.pending.keys.toSet();

    Future<void> archive({required bool archived}) {
      return (env.data.db.update(env.data.db.accessScopes)
            ..where((row) => row.profileId.equals(ids.profile)))
          .write(AccessScopesCompanion(archived: Value(archived)));
    }

    await archive(archived: true);
    await env.service.replan();
    expect(env.scheduler.pending, isEmpty);

    await archive(archived: false);
    await env.service.replan();
    expect(env.scheduler.pending.keys.toSet(), scheduled);
  });

  test('turning the device switch off cancels the reminders of a profile',
      () async {
    final ids = await env.data.seedLocal();
    await planned(ids.profile);

    await env.data.access.setRemindOnDevice(ids.profile, enabled: false);
    await env.service.replan();

    expect(env.scheduler.pending, isEmpty);
  });

  test('a managed profile keeps its zone on a device in another one',
      () async {
    env
      ..deviceTz = 'Europe/Berlin'
      ..data.clock.now = DateTime.utc(2026, 10, 23, 9);
    await env.data.seedLocal(); // managed, Europe/Samara (UTC+4), 08:00

    await env.service.replan();

    // Berlin ends daylight saving on Oct 25: the managed profile does not
    // notice, 08:00 in Samara is 04:00Z on both days.
    expect(
      env.scheduler.byTime.map((r) => r.fireAtUtc),
      [DateTime.utc(2026, 10, 24, 4), DateTime.utc(2026, 10, 25, 4)],
    );
  });

  test('the own self profile follows the device across its daylight saving',
      () async {
    env
      ..deviceTz = 'Europe/Berlin'
      ..data.clock.now = DateTime.utc(2026, 10, 23, 9);
    await env.seed(); // own self, `local` 08:00

    await env.service.replan();

    expect(
      env.scheduler.byTime.map((r) => r.fireAtUtc),
      [DateTime.utc(2026, 10, 24, 6), DateTime.utc(2026, 10, 25, 7)],
    );
  });
}
