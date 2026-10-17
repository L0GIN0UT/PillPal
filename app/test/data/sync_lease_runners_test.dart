import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/data/api/api_client.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/auth/access_claims.dart';
import 'package:pillpal/src/data/api/sync_api.dart';
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/data/clock.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/sync/sync_engine.dart';
import 'package:pillpal/src/data/sync/sync_lease.dart';
import 'package:pillpal/src/data/sync/sync_status.dart';

import 'test_env.dart';

/// Records what is stored and forgotten.
class CountingTokenStore extends InMemoryTokenStore {
  CountingTokenStore(super.initial);

  int writes = 0;
  int clears = 0;

  @override
  Future<void> write(TokenPair tokens) {
    writes++;
    return super.write(tokens);
  }

  @override
  Future<void> clear() {
    clears++;
    return super.clear();
  }
}

/// Records the order of sign-out steps.
class _OrderedStore extends InMemoryTokenStore {
  _OrderedStore(this.events) : super();

  final List<String> events;

  @override
  Future<void> clear() {
    events.add('clear');
    return super.clear();
  }
}

class _OrderedSession implements SessionListener {
  _OrderedSession(this.events);

  final List<String> events;

  @override
  Future<void> signingIn(AccessClaims claims) async {}

  @override
  Future<void> signedOut() async => events.add('signedOut');
}

/// One "isolate": its own API client, engine and lease handle over the
/// database, the keystore and the server it shares with the others.
class Runner {
  Runner(
    TestEnv env,
    CountingTokenStore tokens, {
    http.Client? httpClient,
    bool refreshEnabled = true,
  }) {
    lease = SyncLease(
      db: env.db,
      clock: env.clock.call,
      newId: newUuid,
      // Waiting yields to the event loop without moving the fake clock.
      delay: (_) => Future<void>.delayed(Duration.zero),
    );
    api = ApiClient(
      httpClient: httpClient ?? env.server.client,
      config: ApiConfig(baseUrl: Uri.parse('http://api.test'), region: 'ru'),
      tokens: tokens,
      deviceId: env.syncState.deviceId,
      serverClock: env.serverClock,
      session: env.account,
      lease: lease,
      refreshEnabled: refreshEnabled,
    );
    engine = SyncEngine(
      db: env.db,
      api: SyncApi(api),
      tokens: tokens,
      syncState: env.syncState,
      serverClock: env.serverClock,
      lease: lease,
    );
  }

  late final SyncLease lease;
  late final ApiClient api;
  late final SyncEngine engine;
}

/// The error [call] fails with, or null if it succeeds.
Future<Object?> failureOf(Future<Object?> call) async {
  try {
    await call;
    return null;
  } on Object catch (error) {
    return error;
  }
}

/// Lets the event loop run until [condition] holds.
Future<void> eventually(bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await pumpEventQueue(times: 5);
  }
  expect(condition(), isTrue, reason: 'the condition never became true');
}

void main() {
  late TestEnv env;
  late CountingTokenStore tokens;

  setUp(() async {
    env = await TestEnv.create();
    tokens = CountingTokenStore(await env.tokens.read());
  });
  tearDown(() => env.dispose());

  test('two runners push one at a time', () async {
    await env.seedLocal();
    final gate = env.server.pushGate = Completer<void>();
    final first = Runner(env, tokens).engine.sync(pull: false);
    final second = Runner(env, tokens).engine.sync(pull: false);

    await eventually(() => env.server.pushesInFlight == 1);
    await pumpEventQueue(times: 50);
    expect(env.server.pushesInFlight, 1, reason: 'the other one waits');

    gate.complete();
    final reports = await Future.wait([first, second]);

    expect(reports.every((report) => report.ok), isTrue);
    expect(env.server.maxPushesInFlight, 1);
    expect(
      env.server.pushes,
      hasLength(1),
      reason: 'the second finds it empty',
    );
    expect(await env.outbox(), isEmpty);
  });

  test('two runners refresh the session once', () async {
    env.server.expireAccess();
    final gate = env.server.refreshGate = Completer<void>();
    final first = Runner(env, tokens).api.get('/v1/me');
    final second = Runner(env, tokens).api.get('/v1/me');

    await eventually(() => env.server.refreshCalls == 1);
    await pumpEventQueue(times: 50);
    expect(env.server.refreshCalls, 1, reason: 'the other one waits');

    gate.complete();
    await Future.wait([first, second]);

    expect(env.server.refreshCalls, 1, reason: 'it re-reads the new tokens');
    expect(tokens.writes, 1);
    expect((await tokens.read())!.accessToken, env.server.access);
  });

  test('a stale holder neither stores nor forgets tokens', () async {
    env.server.refreshReuseWindow = true;
    env.server.expireAccess();
    final gate = env.server.refreshGate = Completer<void>();
    final stale = Runner(env, tokens);
    final live = Runner(env, tokens);
    final first = failureOf(stale.api.get('/v1/me'));
    await eventually(() => env.server.refreshCalls == 1);

    // The first request hangs past the TTL; the other runner takes over and
    // rotates the same refresh token (the server answers with the same pair).
    env.clock.advance(SyncLease.defaultTtl + const Duration(seconds: 1));
    final second = live.api.get('/v1/me');
    await eventually(() => env.server.refreshCalls == 2);
    gate.complete();
    final staleError = await first;
    await second;

    expect(tokens.writes, 1, reason: 'only the live holder stores tokens');
    expect(tokens.clears, 0);
    expect((await tokens.read())!.accessToken, env.server.access);
    // The stale one either gave up or adopted the live holder's tokens.
    expect(
      staleError == null ||
          (staleError is ApiException &&
              staleError.code == ApiException.leaseLost),
      isTrue,
      reason: '$staleError',
    );
  });

  test('a stale holder does not forget the session when refused', () async {
    env.server.expireAccess();
    final gate = env.server.refreshGate = Completer<void>();
    final stale = Runner(env, tokens);
    final live = Runner(env, tokens);
    final first = failureOf(stale.api.get('/v1/me'));
    await eventually(() => env.server.refreshCalls == 1);

    env.clock.advance(SyncLease.defaultTtl + const Duration(seconds: 1));
    final second = failureOf(live.api.get('/v1/me'));
    await eventually(() => env.server.refreshCalls == 2);
    env.server.revokeRefreshTokens();
    gate.complete();
    final staleError = await first;
    await second;

    expect(tokens.clears, 1, reason: 'only the live holder forgets tokens');
    expect(staleError, isA<ApiException>());
    expect((staleError! as ApiException).code, 'token_reused');
  });

  test('a stale runner does not apply push results', () async {
    final ids = await env.seedLocal();
    final gate = env.server.pushGate = Completer<void>();
    final first = Runner(env, tokens).engine.sync(pull: false);
    await eventually(() => env.server.pushesInFlight == 1);

    env.clock.advance(SyncLease.defaultTtl + const Duration(seconds: 1));
    final second = Runner(env, tokens).engine.sync(pull: false);
    await eventually(() => env.server.pushesInFlight == 2);
    gate.complete();
    final stale = await first;
    final live = await second;

    expect(stale.errorCode, SyncEngine.leaseLost);
    expect(live.ok, isTrue);
    expect(await env.outbox(), isEmpty);
    expect(env.server.dataOf('medication', ids.medication), isNotNull);
  });

  test('a busy lease defers the run: no error status', () async {
    await env.seedLocal();
    await Runner(env, tokens).lease.tryAcquire();
    final lease = SyncLease(
      db: env.db,
      clock: env.clock.call,
      newId: newUuid,
      maxWait: const Duration(seconds: 1),
      delay: (duration) async => env.clock.advance(duration),
    );
    final engine = SyncEngine(
      db: env.db,
      api: SyncApi(Runner(env, tokens).api),
      tokens: tokens,
      syncState: env.syncState,
      serverClock: env.serverClock,
      lease: lease,
    );

    final report = await engine.sync(pull: false);

    expect(report.errorCode, SyncEngine.syncBusy);
    expect(engine.status.phase, isNot(SyncPhase.error));
    expect(engine.status.errorCode, isNull);
    expect(await env.outbox(), hasLength(3), reason: 'nothing was lost');
  });

  test('a stale run is deferred too, not shown as an error', () async {
    await env.seedLocal();
    final gate = env.server.pushGate = Completer<void>();
    final stale = Runner(env, tokens);
    final first = stale.engine.sync(pull: false);
    await eventually(() => env.server.pushesInFlight == 1);
    env.clock.advance(SyncLease.defaultTtl + const Duration(seconds: 1));
    final second = Runner(env, tokens).engine.sync(pull: false);
    await eventually(() => env.server.pushesInFlight == 2);
    gate.complete();
    final report = await first;
    await second;

    expect(report.errorCode, SyncEngine.leaseLost);
    expect(stale.engine.status.phase, isNot(SyncPhase.error));
  });

  test('without refresh a 401 is deferred and the session is untouched',
      () async {
    env.server.expireAccess();
    final runner = Runner(env, tokens, refreshEnabled: false);

    final error = await failureOf(runner.api.get('/v1/me'));

    expect(error, isA<ApiException>());
    expect((error! as ApiException).code, ApiException.refreshDeferred);
    expect(env.server.refreshCalls, 0);
    expect(tokens.writes + tokens.clears, 0);
  });

  test('sign-out waits for a refresh in flight; the session stays gone',
      () async {
    env.server.expireAccess();
    final gate = env.server.refreshGate = Completer<void>();
    final refreshing = failureOf(Runner(env, tokens).api.get('/v1/me'));
    await eventually(() => env.server.refreshCalls == 1);
    var signedOut = false;
    final out = Runner(env, tokens).api.signOutLocally().then((_) {
      signedOut = true;
    });
    await pumpEventQueue(times: 50);
    expect(signedOut, isFalse, reason: 'it waits for the lease');

    gate.complete();
    await refreshing;
    await out;

    expect(await tokens.read(), isNull);
    expect(await env.syncState.boundUserId(), isNull);
  });

  test('sign-out drops the binding before the tokens', () async {
    final events = <String>[];
    final api = ApiClient(
      httpClient: env.server.client,
      config: ApiConfig(baseUrl: Uri.parse('http://api.test'), region: 'ru'),
      tokens: _OrderedStore(events),
      deviceId: env.syncState.deviceId,
      session: _OrderedSession(events),
    );

    await api.signOutLocally();

    expect(events, ['signedOut', 'clear']);
  });
}
