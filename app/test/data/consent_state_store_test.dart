import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';
import 'test_env.dart';

// `SyncState.consentMissing` (schema 8, ADR 0016 §5): null = not asked yet,
// empty = nothing missing, else the missing kinds.

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  const user = FakeServer.defaultUserId;

  test('is "not asked yet" until an answer is stored', () async {
    expect(await env.syncState.consentMissing(), isNull);
  });

  test('keeps the kinds in order, and an empty list apart from null', () async {
    await env.syncState.saveConsentMissing(user, ['health_data', 'terms']);
    expect(await env.syncState.consentMissing(), ['health_data', 'terms']);

    await env.syncState.saveConsentMissing(user, []);
    expect(await env.syncState.consentMissing(), isEmpty);
    expect(await env.syncState.consentMissing(), isNotNull);

    await env.syncState.forgetConsentMissing();
    expect(await env.syncState.consentMissing(), isNull);
  });

  test('is written only for the account the data is bound to', () async {
    final stored = await env.syncState.saveConsentMissing(
      '0c000000-0000-4000-8000-00000000000c',
      ['health_data'],
    );

    expect(stored, isFalse);
    expect(await env.syncState.consentMissing(), isNull);
  });

  test('is not written while no account is bound', () async {
    final signedOut = await TestEnv.create(signedIn: false);
    addTearDown(signedOut.dispose);

    expect(
      await signedOut.syncState.saveConsentMissing(user, ['health_data']),
      isFalse,
    );
    expect(await signedOut.syncState.consentMissing(), isNull);
  });

  test('binding another account forgets the answer', () async {
    await env.syncState.saveConsentMissing(user, ['health_data']);

    await env.syncState
        .bindAccount('0c000000-0000-4000-8000-00000000000c', 'ru');

    expect(await env.syncState.consentMissing(), isNull);
  });

  test('wiping the account data forgets the answer', () async {
    await env.syncState.saveConsentMissing(user, ['health_data']);

    await env.db.wipeAccountData();

    expect(await env.syncState.consentMissing(), isNull);
  });

  test('the watch follows every change, without repeating a value', () async {
    final seen = <List<String>?>[];
    final subscription = env.syncState.watchConsentMissing().listen(seen.add);
    addTearDown(subscription.cancel);
    await pumpEventQueue();

    await env.syncState.saveConsentMissing(user, ['health_data']);
    await pumpEventQueue();
    await env.syncState.saveConsentMissing(user, ['health_data']);
    await pumpEventQueue();
    await env.syncState.saveConsentMissing(user, []);
    await pumpEventQueue();
    await env.syncState.forgetConsentMissing();
    await pumpEventQueue();

    expect(seen, [
      null,
      ['health_data'],
      <String>[],
      null,
    ]);
  });
}
