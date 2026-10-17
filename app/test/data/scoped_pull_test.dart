import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/sync/scoped_puller.dart';
import 'package:pillpal/src/data/sync/server_state_applier.dart';

import 'fake_server.dart';
import 'scope_fixtures.dart';
import 'test_env.dart';

// The client side of POST /v1/sync/pull (ADR 0006 §2, §7).

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  Future<List<ProfileRow>> profilesOf() => env.db.select(env.db.profiles).get();

  test('a relative scope arrives with its role and projected rows', () async {
    final ids = seedRelative(env);

    await env.engine.sync();

    final scope = (await env.access.scope(ids.profile))!;
    expect(scope.role, ScopeRole.viewer);
    expect(scope.kind, 'self');
    expect(scope.cursor, greaterThan(0));
    expect((await env.medications.find(ids.medication))!.name, isNotNull);
    expect(await env.schedules.find(ids.schedule), isNotNull);
  });

  test('scopes are requested in groups of at most 50', () async {
    for (var i = 0; i < 120; i++) {
      env.server.seed(
        'profile',
        'p-${i.toString().padLeft(3, '0')}',
        data: {'kind': 'managed', 'display_name': 'P$i', 'timezone': 'UTC'},
        key: env.clock.now,
      );
    }

    await env.engine.sync();

    final sizes = [for (final c in env.server.pullCursors.skip(1)) c.length];
    expect(sizes, [50, 50, 20]);
    expect(SyncLimits.pullScopes, 50);
    expect(await profilesOf(), hasLength(120));
  });

  test('a revoked grant evicts the scope with everything in it', () async {
    final ids = seedRelative(env);
    await env.engine.sync();
    expect(await env.access.scope(ids.profile), isNotNull);

    env.server.sync.revoke(ids.profile, FakeServer.defaultUserId);
    await env.engine.sync();

    expect(await env.access.scope(ids.profile), isNull);
    expect(await env.profiles.find(ids.profile), isNull);
    expect(await env.medications.find(ids.medication), isNull);
    expect(await env.schedules.find(ids.schedule), isNull);
  });

  test('a local foreign scope the server does not list is evicted', () async {
    final ids = seedRelative(env);
    await env.engine.sync();
    await env.db.into(env.db.accessScopes).insert(
          AccessScopesCompanion.insert(
            profileId: 'ghost',
            role: ScopeRole.viewer,
            kind: 'self',
          ),
        );

    await env.engine.sync();

    expect(await env.access.scope('ghost'), isNull);
    expect(await env.access.scope(ids.profile), isNotNull);
  });

  test('a role change evicts, drops the page and restarts at cursor 0',
      () async {
    final ids = seedRelative(env);
    await env.engine.sync();
    env.server.seed(
      'medication',
      'rel-extra',
      user: relativeUserId,
      data: {...redactedMedication(ids.profile)},
    );

    env.server.grant(ids.profile, FakeServer.defaultUserId, ScopeRole.editor);
    await env.engine.sync();

    final scope = (await env.access.scope(ids.profile))!;
    expect(scope.role, ScopeRole.editor);
    expect(scope.cursor, 0);
    expect(await env.medications.find(ids.medication), isNull);
    expect(await env.medications.find('rel-extra'), isNull,
        reason: 'changes of the page are dropped with the scope');

    await env.engine.sync();

    expect(await env.medications.find(ids.medication), isNotNull);
    expect(await env.medications.find('rel-extra'), isNotNull);
    expect((await env.access.scope(ids.profile))!.cursor, greaterThan(0));
  });

  test('the archived flag is stored', () async {
    final ids = seedRelative(env, role: ScopeRole.guardian);
    await env.engine.sync();
    expect((await env.access.scope(ids.profile))!.archived, isFalse);

    env.server.sync.setArchived(ids.profile, archived: true);
    await env.engine.sync();

    expect((await env.access.scope(ids.profile))!.archived, isTrue);
  });

  test('an unfinished backfill is echoed in the next request', () async {
    final ids = seedRelative(env);
    env.server.sync.setBackfillUntil(ids.profile, 1000);

    await env.engine.sync();
    expect((await env.access.scope(ids.profile))!.backfillUntil, 1000);
    await env.engine.sync();

    final last = env.server.pulls.last;
    expect(last['backfill_until'], {ids.profile: 1000});
  });

  group('stale scopes', () {
    late ScopedPuller puller;

    setUp(() {
      puller = ScopedPuller(
        db: env.db,
        api: env.syncApi,
        applier: ServerStateApplier(env.db),
        clock: env.clock.call,
      );
    });

    test('a foreign scope not pulled for the grace period is evicted',
        () async {
      final ids = seedRelative(env);
      env.server.seed(
        'profile',
        'own-p',
        data: {'kind': 'self', 'display_name': 'Me', 'timezone': 'UTC'},
        key: env.clock.now,
      );
      await env.engine.sync();

      env.clock.advance(SyncLimits.staleScopeAfter + const Duration(hours: 1));
      final evicted = await puller.evictStaleScopes();

      expect(evicted, 1);
      expect(await env.access.scope(ids.profile), isNull);
      expect(await env.medications.find(ids.medication), isNull);
      expect(await env.access.scope('own-p'), isNotNull, reason: 'own is kept');
    });

    test('a recently pulled scope stays', () async {
      final ids = seedRelative(env);
      await env.engine.sync();

      env.clock.advance(SyncLimits.staleScopeAfter - const Duration(hours: 1));

      expect(await puller.evictStaleScopes(), 0);
      expect(await env.access.scope(ids.profile), isNotNull);
    });
  });
}
