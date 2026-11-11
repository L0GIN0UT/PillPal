import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/api/consents_api.dart';
import 'package:pillpal/src/data/api/consents_dto.dart';

import 'fake_server.dart';
import 'test_env.dart';

void main() {
  late TestEnv env;
  late ConsentsApi api;

  setUp(() async {
    env = await TestEnv.create();
    api = ConsentsApi(env.api);
  });
  tearDown(() => env.dispose());

  const user = FakeServer.defaultUserId;

  test('reads the versions to show and the kinds still missing', () async {
    env.server.consentsMissing = ['health_data', 'terms'];

    final state = await api.get(userId: user);

    expect(state.missing, ['health_data', 'terms']);
    expect(state.current['health_data'], 1);
    expect(state.records, isEmpty);
  });

  test('sends exactly the kind and the version the app displayed', () async {
    env.server.consentsMissing = ['terms'];

    final record = await api.accept(
      const ConsentGrant(kind: ConsentKind.terms, version: 1),
      userId: user,
    );

    expect(record.kind, 'terms');
    expect(record.withdrawnAt, isNull);
    final sent = env.server.requests.last;
    expect((sent.method, sent.path), ('POST', '/v1/me/consents'));
    expect(sent.body, {'kind': 'terms', 'version': 1});
  });

  test('a replay (200) counts as accepted like a new record (201)', () async {
    const grant = ConsentGrant(kind: ConsentKind.privacy, version: 1);

    final first = await api.accept(grant, userId: user);
    final replay = await api.accept(grant, userId: user);

    expect(first.kind, replay.kind);
  });

  test('a version the server no longer accepts is a 422 code', () async {
    await expectLater(
      api.accept(
        const ConsentGrant(kind: ConsentKind.terms, version: 7),
        userId: user,
      ),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', ConsentErrors.unsupportedVersion)
            .having((e) => e.status, 'status', 422),
      ),
    );
  });

  test('refuses to run for an account that is not the signed-in one', () async {
    await expectLater(
      api.get(userId: '0c000000-0000-4000-8000-00000000000c'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', ApiException.accountChanged),
      ),
    );
    expect(env.server.requests, isEmpty);
  });

  group('withdraw', () {
    test('sends the kind and returns how many links were reset', () async {
      env.server.linksResetOnWithdraw = 3;

      final reset = await api.withdraw(
        ConsentKind.catalogContribution,
        userId: user,
      );

      expect(reset, 3);
      final sent = env.server.requests.last;
      expect((sent.method, sent.path), ('POST', '/v1/me/consents/withdraw'));
      expect(sent.body, {'kind': 'catalog_contribution'});
    });

    test('a replay resets nothing', () async {
      env.server.linksResetOnWithdraw = 3;
      await api.withdraw(ConsentKind.catalogContribution, userId: user);

      final replay = await api.withdraw(
        ConsentKind.catalogContribution,
        userId: user,
      );

      expect(replay, 0);
    });

    test('health data is withdrawn by deleting the account (409)', () async {
      await expectLater(
        api.withdraw(ConsentKind.healthData, userId: user),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'withdraw_via_account_deletion')
              .having((e) => e.status, 'status', 409),
        ),
      );
    });

    test('refuses to run for an account that is not the signed-in one',
        () async {
      await expectLater(
        api.withdraw(
          ConsentKind.catalogContribution,
          userId: '0c000000-0000-4000-8000-00000000000c',
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ApiException.accountChanged),
        ),
      );
      expect(env.server.requests, isEmpty);
    });
  });

  group('storedMissing', () {
    ConsentsState state(List<String> missing, List<ConsentRecord> records) =>
        ConsentsState(current: const {}, records: records, missing: missing);

    ConsentRecord record(String kind, {bool withdrawn = false}) =>
        ConsentRecord(
          id: 'r',
          kind: kind,
          version: 1,
          source: 'registration',
          acceptedAt: DateTime.utc(2026, 10),
          withdrawnAt: withdrawn ? DateTime.utc(2026, 10, 2) : null,
        );

    test('an active older record marks health data as outdated only', () {
      final stored = state(
        ['health_data', 'terms'],
        [record('health_data'), record('terms', withdrawn: true)],
      ).storedMissing;

      expect(stored, ['~health_data', 'terms']);
      expect(StoredConsents.pausesSync(stored), isFalse);
      expect(StoredConsents.kindOf('~health_data'), 'health_data');
    });

    test('never recorded or withdrawn stays a plain, pausing kind', () {
      expect(
        state(['health_data'], []).storedMissing,
        ['health_data'],
      );
      expect(
        StoredConsents.pausesSync(
          state(['health_data'], [record('health_data', withdrawn: true)])
              .storedMissing,
        ),
        isTrue,
      );
    });
  });

  test('unknown kinds of a newer server are kept as text', () async {
    env.server.consentsMissing = ['marketing', 'terms'];

    final state = await api.get(userId: user);

    expect(state.missing, ['marketing', 'terms']);
    expect(ConsentKind.tryParse('marketing'), isNull);
    expect(ConsentKind.tryParse('terms'), ConsentKind.terms);
  });
}
