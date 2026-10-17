import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';

import 'scope_fixtures.dart';
import 'test_env.dart';

// The own self profile is kind `self` in a scope where the account is the
// owner; a relative's self profile never qualifies (ADR 0006 §6).

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  test('a relative self profile is not the own self profile', () async {
    final ids = seedRelative(env, role: ScopeRole.guardian);
    await env.engine.sync();
    final own = await env.seedOwnSelfProfile();

    final found = await env.access.ownSelfProfile();

    expect(found?.id, own);
    expect(await env.profiles.find(ids.profile), isNotNull);
  });

  test('without an owner scope there is no own self profile', () async {
    seedRelative(env);
    await env.engine.sync();

    expect(await env.access.ownSelfProfile(), isNull);
  });

  test('syncDeviceZone updates the own self profile and queues it', () async {
    final own = await env.seedOwnSelfProfile(timezone: 'Europe/Samara');
    await env.profiles.syncDeviceZone('Europe/Berlin');

    expect((await env.profiles.find(own))!.timezone, 'Europe/Berlin');
    final entries = await env.outbox();
    expect(entries.single.entityKind, 'profile');
    expect(entries.single.profileId, own);
  });

  test('syncDeviceZone changes nothing when the zone is the same', () async {
    await env.seedOwnSelfProfile(timezone: 'Europe/Berlin');

    await env.profiles.syncDeviceZone('Europe/Berlin');

    expect(await env.outbox(), isEmpty);
  });

  test('syncDeviceZone never touches other profiles', () async {
    final ids = seedRelative(env, role: ScopeRole.guardian);
    await env.engine.sync();
    await env.seedOwnSelfProfile();
    await env.db.delete(env.db.outbox).go();

    await env.profiles.syncDeviceZone('Asia/Tokyo');

    expect((await env.profiles.find(ids.profile))!.timezone, 'Europe/Berlin');
    final managed = await env.db.select(env.db.profiles).get();
    expect(managed.where((p) => p.timezone == 'Asia/Tokyo'), hasLength(1));
  });

  test('the own self profile stream ignores writes to the scope row',
      () async {
    final own = await env.seedOwnSelfProfile();
    final emitted = <String?>[];
    final subscription = env.access
        .watchOwnSelfProfile()
        .listen((profile) => emitted.add(profile?.id));
    addTearDown(subscription.cancel);
    await pumpEventQueue();
    expect(emitted, [own]);

    // What every pulled page writes: the cursor and the pull time.
    await env.db.update(env.db.accessScopes).write(
          const AccessScopesCompanion(
            cursor: Value(7),
            lastPulledAt: Value(1),
          ),
        );
    await pumpEventQueue();

    expect(emitted, [own], reason: 'the profile did not change');

    await env.profiles.syncDeviceZone('Asia/Tokyo');
    await pumpEventQueue();
    expect(emitted, [own, own], reason: 'a changed profile is emitted');
  });
}
