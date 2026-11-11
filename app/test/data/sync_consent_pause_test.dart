import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/api/consents_api.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/repositories/medication_draft.dart';
import 'package:pillpal/src/data/sync/medical_sync_gate.dart';
import 'package:pillpal/src/data/sync/sync_engine.dart';
import 'package:pillpal/src/data/sync/sync_status.dart';

import 'fake_server.dart';
import 'scope_fixtures.dart';
import 'test_env.dart';

// ADR 0016 §5: while the consent for health data is missing the whole run is
// paused - no push, no pull, no reads - and nothing local changes.

const String _health = 'health_data';
const String _ownProfile = 'own-profile';

void main() {
  late TestEnv env;
  late SyncEngine engine;

  setUp(() async {
    env = await TestEnv.create();
    engine = SyncEngine(
      db: env.db,
      api: env.syncApi,
      tokens: env.tokens,
      syncState: env.syncState,
      gate: ConsentSyncGate(
        syncState: env.syncState,
        api: ConsentsApi(env.api),
      ),
      serverClock: env.serverClock,
    );
  });

  tearDown(() async {
    await engine.dispose();
    await env.dispose();
  });

  Future<void> storeMissing(List<String> kinds) async {
    final stored = await env.syncState.saveConsentMissing(
      FakeServer.defaultUserId,
      kinds,
    );
    expect(stored, isTrue);
  }

  List<String> consentGets() => [
        for (final request in env.server.requests)
          if (request.path == '/v1/me/consents') request.method,
      ];

  List<String> syncPaths() => [
        for (final request in env.server.requests)
          if (request.path != '/v1/me/consents') request.path,
      ];

  void seedOwnProfile() {
    env.server.seed(
      'profile',
      _ownProfile,
      data: {'kind': 'self', 'display_name': 'Me', 'timezone': 'UTC'},
      key: env.clock.now,
    );
  }

  group('paused', () {
    test('sends and reads nothing, and leaves the outbox and cursors alone',
        () async {
      await env.seedLocal();
      await storeMissing([_health, 'terms', 'privacy']);
      final outbox = await env.outbox();
      final scopes = await env.db.select(env.db.accessScopes).get();
      expect(outbox, hasLength(3));

      final report = await engine.sync();

      expect(report.errorCode, SyncEngine.consentRequired);
      expect(report.ok, isFalse);
      expect(engine.status.phase, SyncPhase.idle, reason: 'not an error');
      expect(engine.status.errorCode, isNull);
      expect(env.server.requests, isEmpty, reason: 'not even a read');
      expect(await env.outbox(), outbox, reason: 'rows, seq, attempts intact');
      expect(await env.db.select(env.db.accessScopes).get(), scopes);
    });

    test('flush before a sign-out does nothing', () async {
      await env.seedLocal();
      await storeMissing([_health]);
      final outbox = await env.outbox();

      await engine.flush();

      expect(env.server.requests, isEmpty);
      expect(await env.outbox(), outbox);
    });

    test('the eviction of stale foreign scopes still runs', () async {
      final ids = seedRelative(env);
      seedOwnProfile();
      await env.engine.sync();
      expect(await env.access.scope(ids.profile), isNotNull);
      await storeMissing([_health]);
      env.server.requests.clear();

      env.clock.advance(SyncLimits.staleScopeAfter + const Duration(hours: 1));
      final report = await engine.sync();

      expect(report.errorCode, SyncEngine.consentRequired);
      expect(await env.access.scope(ids.profile), isNull);
      expect(await env.access.scope(_ownProfile), isNotNull);
      expect(env.server.requests, isEmpty);
    });

    test('only terms or privacy missing does not pause the sync', () async {
      await env.seedLocal();
      await storeMissing(['terms', 'privacy']);

      final report = await engine.sync();

      expect(report.ok, isTrue);
      expect(report.pushed, 3);
      expect(consentGets(), isEmpty, reason: 'the stored answer decides');
    });
  });

  group('without a stored answer', () {
    test('asks the server exactly once, before the first push', () async {
      await env.seedLocal();
      expect(await env.syncState.consentMissing(), isNull);

      final report = await engine.sync();

      expect(report.ok, isTrue);
      expect(consentGets(), ['GET']);
      expect(env.server.requests.first.path, '/v1/me/consents');
      expect(env.server.pushes, isNotEmpty);
      expect(await env.syncState.consentMissing(), isEmpty);
    });

    test('a missing health data consent pauses it and stores the answer',
        () async {
      env.server.consentsMissing = [_health, 'terms'];
      await env.seedLocal();
      final outbox = await env.outbox();

      final report = await engine.sync();

      expect(report.errorCode, SyncEngine.consentRequired);
      expect(consentGets(), ['GET']);
      expect(syncPaths(), isEmpty);
      expect(await env.syncState.consentMissing(), [_health, 'terms']);
      expect(await env.outbox(), outbox);

      await engine.sync();
      expect(consentGets(), ['GET'], reason: 'the stored answer is reused');
    });

    test('only terms missing does not pause it', () async {
      env.server.consentsMissing = ['terms'];
      await env.seedLocal();

      final report = await engine.sync();

      expect(report.ok, isTrue);
      expect(report.pushed, 3);
    });

    test('a network error is reported and nothing is sent', () async {
      env.server.consentsOffline = true;
      await env.seedLocal();
      final outbox = await env.outbox();

      final report = await engine.sync();

      expect(report.errorCode, ApiException.networkError);
      expect(syncPaths(), isEmpty);
      expect(await env.outbox(), outbox);
      expect(await env.syncState.consentMissing(), isNull);
    });

    test('an account that changes during the question stops the run', () async {
      await env.seedLocal();
      env.server.duringConsents = () async {
        await env.syncState
            .bindAccount('0c000000-0000-4000-8000-00000000000c', 'ru');
      };

      final report = await engine.sync();

      expect(report.errorCode, SyncEngine.accountChanged);
      expect(syncPaths(), isEmpty);
      expect(
        await env.syncState.consentMissing(),
        isNull,
        reason: 'the answer is not stored for the new account',
      );
    });
  });

  group('resume', () {
    test('pushes the paused rows in seq order, then pulls from the old cursor',
        () async {
      seedOwnProfile();
      await env.engine.sync();
      final cursors = {
        for (final scope in await env.db.select(env.db.accessScopes).get())
          scope.profileId: scope.cursor,
      };
      expect(cursors[_ownProfile], greaterThan(0));
      await storeMissing([_health]);
      final first = await env.medications.create(
        profileId: _ownProfile,
        draft: const MedicationDraft(name: 'Med A'),
      );
      env.clock.advance(const Duration(minutes: 1));
      final second = await env.medications.create(
        profileId: _ownProfile,
        draft: const MedicationDraft(name: 'Med B'),
      );
      final waiting = await env.outbox();
      final pushedBefore = env.server.pushes.length;
      env.server.requests.clear();

      expect((await engine.sync()).errorCode, SyncEngine.consentRequired);
      expect(env.server.requests, isEmpty);
      expect(await env.outbox(), waiting);

      await storeMissing([]);
      final report = await engine.sync();

      expect(report.ok, isTrue);
      expect(await env.outbox(), isEmpty);
      final sent = [
        for (final batch in env.server.pushes.skip(pushedBefore))
          for (final mutation in batch) mutation['id'],
      ];
      expect(sent, [first, second]);
      expect(env.server.pullCursors.first, cursors);
    });
  });
}
