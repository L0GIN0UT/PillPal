import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/reminders/reminder_inputs.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../data/test_env.dart';
import 'reminder_test_env.dart';

// Which profiles may remind on this device and in which zone (ADR 0006 §6,
// decision D4).

void main() {
  late ReminderTestEnv env;
  late ReminderInputsLoader loader;

  setUp(() async {
    env = await ReminderTestEnv.create();
    loader = ReminderInputsLoader(env.data.db);
  });
  tearDown(() => env.dispose());

  Future<void> setRole(String profile, String role) {
    return (env.data.db.update(env.data.db.accessScopes)
          ..where((row) => row.profileId.equals(profile)))
        .write(AccessScopesCompanion(role: Value(role)));
  }

  Future<Set<String>> remindingSchedules() async =>
      (await loader.load(env.data.clock.now)).targets.keys.toSet();

  test('only owner and guardian scopes remind', () async {
    final managed = await env.data.seedLocal();

    expect(await remindingSchedules(), {managed.schedule});
    await setRole(managed.profile, 'guardian');
    expect(await remindingSchedules(), {managed.schedule});
    await setRole(managed.profile, 'editor');
    expect(await remindingSchedules(), isEmpty);
    await setRole(managed.profile, 'viewer');
    expect(await remindingSchedules(), isEmpty);
  });

  test('an archived scope does not remind', () async {
    final managed = await env.data.seedLocal();
    await (env.data.db.update(env.data.db.accessScopes)
          ..where((row) => row.profileId.equals(managed.profile)))
        .write(const AccessScopesCompanion(archived: Value(true)));

    expect(await remindingSchedules(), isEmpty);
  });

  test('the device switch turns a managed profile off and on', () async {
    final managed = await env.data.seedLocal();
    await env.data.access.setRemindOnDevice(managed.profile, enabled: false);
    expect(await remindingSchedules(), isEmpty);

    await env.data.access.setRemindOnDevice(managed.profile, enabled: true);
    expect(await remindingSchedules(), {managed.schedule});
  });

  test('a redacted medication never produces a reminder', () async {
    final managed = await env.data.seedLocal();
    await (env.data.db.update(env.data.db.medications)
          ..where((row) => row.id.equals(managed.medication)))
        .write(const MedicationsCompanion(redacted: Value(true)));

    expect(await remindingSchedules(), isEmpty);
  });

  test('a managed profile keeps its own zone, the own self follows the device',
      () async {
    final managed = await env.data.seedLocal(); // local, Europe/Samara
    final own = await env.data.seedLocal(ownSelf: true);

    final inputs = await loader.load(env.data.clock.now);

    final managedSource = inputs.targets[managed.schedule]!.source;
    expect(managedSource.tzMode, TzMode.fixed);
    expect(managedSource.fixedTz, 'Europe/Samara');
    final ownSource = inputs.targets[own.schedule]!.source;
    expect(ownSource.tzMode, TzMode.local);
    expect(ownSource.fixedTz, isNull);
    expect(inputs.fallbackTimeZone, 'Europe/Samara');
  });

  test('a relative self profile with a guardian role keeps its zone', () async {
    final own = await env.data.seedLocal(ownSelf: true);
    final other = await env.data.seedLocal();
    await (env.data.db.update(env.data.db.profiles)
          ..where((row) => row.id.equals(other.profile)))
        .write(const ProfilesCompanion(kind: Value('self')));
    await (env.data.db.update(env.data.db.accessScopes)
          ..where((row) => row.profileId.equals(other.profile)))
        .write(
      const AccessScopesCompanion(
        role: Value('guardian'),
        kind: Value('self'),
      ),
    );

    final inputs = await loader.load(env.data.clock.now);

    expect(inputs.targets[other.schedule]!.source.tzMode, TzMode.fixed);
    expect(inputs.targets[own.schedule]!.source.tzMode, TzMode.local);
  });
}
