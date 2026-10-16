import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';

import 'fake_server.dart';
import 'sync_fixtures.dart';
import 'test_env.dart';

const _userB = '0b000000-0000-4000-8000-00000000000b';

void main() {
  late TestEnv env;

  setUp(() async {
    env = await TestEnv.create(signedIn: false);
    env.server.addUser('b@example.com', 'pass-b-123', _userB);
  });
  tearDown(() => env.dispose());

  Future<void> loginA() => env.authApi
      .login(email: FakeServer.defaultEmail, password: 'correct-pass');
  Future<void> loginB() =>
      env.authApi.login(email: 'b@example.com', password: 'pass-b-123');

  test('logout erases A; B never pushes A data and pulls from 0', () async {
    await loginA();
    final a = await env.seedLocal();
    await env.engine.sync();
    expect(await env.syncState.cursor(), greaterThan(0));
    await env.medications.update(
      a.medication,
      const MedicationDraft(name: 'Unsynced'),
    );
    // Offline at logout: the best-effort flush cannot push.
    env.server.responder = (m) => rejected(m, 'clock_skew');

    await env.authApi.logout();

    expect(await env.tokens.read(), isNull);
    expect(await env.outbox(), isEmpty);
    expect(await env.db.select(env.db.profiles).get(), isEmpty);
    expect(await env.syncState.cursor(), 0);

    env.server.responder = null;
    final pushesBefore = env.server.pushes.length;
    final requestsBefore = env.server.requests.length;
    await loginB();
    await env.engine.sync();

    final aIds = {a.profile, a.medication, a.schedule};
    final pushedByB = [
      for (final batch in env.server.pushes.skip(pushesBefore))
        for (final m in batch) m['id'],
    ];
    expect(pushedByB.where(aIds.contains), isEmpty);
    final pulls = [
      for (final r in env.server.requests.skip(requestsBefore))
        if (r.path == '/v1/sync/pull') r.query['cursor'],
    ];
    expect(pulls.first, '0');
    expect(await env.db.select(env.db.profiles).get(), isEmpty);
    expect(await env.syncState.boundUserId(), _userB);
    expect(env.server.dataOf('medication', a.medication)!['name'], 'Med A');
  });

  test('signing in as another account without logout erases first', () async {
    await loginA();
    await env.seedLocal();
    await loginB();
    expect(await env.outbox(), isEmpty);
    expect(await env.db.select(env.db.medications).get(), isEmpty);
    expect(await env.syncState.boundUserId(), _userB);
  });

  test('signing in again as the same account keeps local data', () async {
    await loginA();
    final ids = await env.seedLocal();
    await loginA();
    expect(await env.medications.find(ids.medication), isNotNull);
    expect(await env.outbox(), hasLength(3));
  });

  test('data written before the first sign-in is adopted', () async {
    final ids = await env.seedLocal();
    await loginA();
    await env.engine.sync();
    expect(env.server.dataOf('schedule', ids.schedule), isNotNull);
    expect(await env.syncState.boundUserId(), FakeServer.defaultUserId);
  });

  test('after a forced sign-out, the same account pushes the outbox', () async {
    await loginA();
    final ids = await env.seedLocal();
    env.server.expireAccess();
    env.server.revokeRefreshTokens();
    final report = await env.engine.sync();
    expect(report.errorCode, 'token_reused');
    expect(await env.tokens.read(), isNull);
    expect(await env.outbox(), hasLength(3), reason: 'nothing is lost');

    await loginA();
    expect(await env.outbox(), hasLength(3));
    final retry = await env.engine.sync();

    expect(retry.ok, isTrue);
    expect(retry.pushed, 3);
    expect(env.server.dataOf('schedule', ids.schedule), isNotNull);
  });

  test('after a forced sign-out, another account erases the data', () async {
    await loginA();
    await env.seedLocal();
    env.server.expireAccess();
    env.server.revokeRefreshTokens();
    await env.engine.sync();

    await loginB();

    expect(await env.outbox(), isEmpty);
    expect(await env.db.select(env.db.profiles).get(), isEmpty);
  });

  test('sync refuses tokens the local data is not bound to', () async {
    await env.seedLocal();
    // Tokens stored behind the binding's back: unbound data ...
    await env.tokens.write(_tokens(env.server.issueTokens(_userB), env));
    final unbound = await env.engine.sync();
    expect(unbound.errorCode, 'account_changed');

    // ... and data bound to another account.
    await loginA();
    await env.tokens.write(_tokens(env.server.issueTokens(_userB), env));
    final foreign = await env.engine.sync();
    expect(foreign.errorCode, 'account_changed');

    expect(env.server.pushes, isEmpty);
    expect(await env.outbox(), hasLength(3));
    expect(await env.syncState.boundUserId(), FakeServer.defaultUserId);
  });
}

TokenPair _tokens(Json pair, TestEnv env) => TokenPair(
      accessToken: pair['access_token']! as String,
      refreshToken: pair['refresh_token']! as String,
      accessExpiresAt: env.clock.now.add(const Duration(minutes: 15)),
    );
