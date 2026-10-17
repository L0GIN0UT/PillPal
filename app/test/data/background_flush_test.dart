import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/data/api/api_client.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/api/sync_api.dart';
import 'package:pillpal/src/data/auth/access_claims.dart';
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/data/clock.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/sync/background_flush.dart';
import 'package:pillpal/src/data/sync/sync_engine.dart';
import 'package:pillpal/src/data/sync/sync_lease.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'fake_server.dart';
import 'test_env.dart';

class _FakeScheduler implements BackgroundFlushScheduler {
  final List<String> enqueued = [];

  @override
  Future<void> enqueue(String userId) async => enqueued.add(userId);
}

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  /// The flush of a background engine: own lease handle, shared database
  /// and keystore, and its own transport ([httpClient]).
  BackgroundFlush flush({
    TokenStore? tokens,
    http.Client? httpClient,
  }) {
    final store = tokens ?? env.tokens;
    final lease = SyncLease(
      db: env.db,
      clock: env.clock.call,
      newId: newUuid,
      delay: (_) => Future<void>.delayed(Duration.zero),
    );
    final api = ApiClient(
      httpClient: httpClient ?? env.server.client,
      config: ApiConfig(baseUrl: Uri.parse('http://api.test'), region: 'ru'),
      tokens: store,
      deviceId: env.syncState.deviceId,
      serverClock: env.serverClock,
      session: BackgroundSession(env.syncState),
      lease: lease,
    );
    return BackgroundFlush(
      db: env.db,
      tokens: store,
      syncState: env.syncState,
      engine: SyncEngine(
        db: env.db,
        api: SyncApi(api),
        tokens: store,
        syncState: env.syncState,
        serverClock: env.serverClock,
        lease: lease,
      ),
    );
  }

  test('pushes the outbox in order and never pulls', () async {
    final ids = await env.seedLocal();
    await env.doseEvents.record(
      medicationId: ids.medication,
      type: DoseEventType.taken,
      at: env.clock.now,
    );
    final before = await env.outbox();
    expect(before.length, greaterThan(3));

    final outcome = await flush().run(userId: FakeServer.defaultUserId);

    expect(outcome, BackgroundFlushOutcome.flushed);
    final sent = [
      for (final batch in env.server.pushes)
        for (final mutation in batch) mutation['id'],
    ];
    expect(sent, [for (final entry in before) entry.entityId]);
    expect(await env.outbox(), isEmpty);
    expect(env.server.pulls, isEmpty, reason: 'push only');
    expect(
      env.server.requests.map((request) => request.path).toSet(),
      {'/v1/sync/push'},
    );
  });

  test('nothing pending: no request at all', () async {
    final outcome = await flush().run(userId: FakeServer.defaultUserId);

    expect(outcome, BackgroundFlushOutcome.nothingPending);
    expect(env.server.requests, isEmpty);
  });

  test('another account than the one the job was queued for: no flush',
      () async {
    await env.seedLocal();

    final outcome = await flush().run(userId: 'someone-else');

    expect(outcome, BackgroundFlushOutcome.accountChanged);
    expect(env.server.requests, isEmpty);
    expect(await env.outbox(), hasLength(3));
  });

  test('tokens of another account than the bound one: no flush', () async {
    await env.seedLocal();
    final other = env.server.issueTokens(
      '0b000000-0000-4000-8000-00000000000b',
    );
    await env.tokens.write(
      TokenPair(
        accessToken: other['access_token']! as String,
        refreshToken: other['refresh_token']! as String,
        accessExpiresAt: env.clock.now.add(const Duration(minutes: 15)),
      ),
    );

    final outcome = await flush().run(userId: FakeServer.defaultUserId);

    expect(outcome, BackgroundFlushOutcome.accountChanged);
    expect(env.server.requests, isEmpty);
    expect(await env.outbox(), hasLength(3));
  });

  test('signed out: no flush, the outbox stays', () async {
    await env.seedLocal();
    await env.tokens.clear();

    final outcome = await flush().run(userId: FakeServer.defaultUserId);

    expect(outcome, BackgroundFlushOutcome.signedOut);
    expect(env.server.requests, isEmpty);
    expect(await env.outbox(), hasLength(3));
  });

  test('a lost account binding (sign-out wiped the data): no flush', () async {
    await env.seedLocal();
    await env.account.signedOut();

    final outcome = await flush().run(userId: FakeServer.defaultUserId);

    expect(outcome, BackgroundFlushOutcome.accountChanged);
    expect(env.server.requests, isEmpty);
  });

  test('offline: retry later, nothing is lost', () async {
    await env.seedLocal();
    final offline = MockClient(
      (request) async => throw http.ClientException('offline'),
    );

    final outcome = await flush(httpClient: offline).run(
      userId: FakeServer.defaultUserId,
    );

    expect(outcome, BackgroundFlushOutcome.retryLater);
    expect(await env.outbox(), hasLength(3));
  });

  test('a rejected session is not retried and keeps the outbox', () async {
    await env.seedLocal();
    env.server.expireAccess();
    env.server.revokeRefreshTokens();

    final outcome = await flush().run(userId: FakeServer.defaultUserId);

    expect(outcome, BackgroundFlushOutcome.failed);
    expect(await env.outbox(), hasLength(3));
    expect(await env.tokens.read(), isNull);
  });

  test('an expired access token is refreshed in the background', () async {
    await env.seedLocal();
    env.server.expireAccess();

    final outcome = await flush().run(userId: FakeServer.defaultUserId);

    expect(outcome, BackgroundFlushOutcome.flushed);
    expect(env.server.refreshCalls, 1);
    expect(await env.outbox(), isEmpty);
  });

  group('BackgroundSession', () {
    test('never wipes the data: a foreign account is refused', () async {
      await env.seedLocal();
      final session = BackgroundSession(env.syncState);

      await session.signingIn(
        const AccessClaims(userId: FakeServer.defaultUserId, region: 'ru'),
      );
      await expectLater(
        session.signingIn(const AccessClaims(userId: 'other', region: 'ru')),
        throwsA(isA<ApiException>()),
      );
      await session.signedOut();

      expect(await env.outbox(), hasLength(3));
    });
  });

  group('enqueueFlushAfterAction', () {
    test('queues one job for the bound account', () async {
      final scheduler = _FakeScheduler();

      await enqueueFlushAfterAction(
        syncState: env.syncState,
        scheduler: scheduler,
      );

      expect(scheduler.enqueued, [FakeServer.defaultUserId]);
    });

    test('queues nothing without a bound account', () async {
      await env.account.signedOut();
      final scheduler = _FakeScheduler();

      await enqueueFlushAfterAction(
        syncState: env.syncState,
        scheduler: scheduler,
      );

      expect(scheduler.enqueued, isEmpty);
    });
  });
}
