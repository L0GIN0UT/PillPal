import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/consents_dto.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/auth/auth_session.dart';
import 'package:pillpal/src/features/consent/consent_gate_controller.dart';

import '../helpers.dart';
import '../support/consent_server.dart';

// The consent gate controller (ADR 0016 §5): what it asks, what it stores and
// when the paused sync resumes.

const String _user = 'user-1';
const List<String> _all = ['health_data', 'terms', 'privacy'];

class _Env {
  _Env(this.server, this.harness, this.container);

  final FakeConsentServer server;
  final TestHarness harness;
  final ProviderContainer container;

  ConsentGateController get gate =>
      container.read(consentGateProvider.notifier);

  ConsentGateState get state => container.read(consentGateProvider);

  Future<List<String>?> stored() =>
      container.read(syncStateStoreProvider).consentMissing();
}

/// A signed-in account whose stored answer is [stored] and whose server
/// lacks [missing].
Future<_Env> _env({
  List<String> missing = _all,
  List<String>? stored = _all,
}) async {
  final server = FakeConsentServer(missing: missing);
  final harness = TestHarness(handler: server.handle);
  final container = createContainer(harness);
  final store = container.read(syncStateStoreProvider);
  await store.bindAccount(_user, 'ru');
  if (stored != null) {
    await store.saveConsentMissing(_user, stored);
  }
  expect(await container.read(authSessionProvider.future), isTrue);
  return _Env(server, harness, container);
}

void main() {
  group('accept', () {
    test('records the ticked texts in the order of the screen, then asks',
        () async {
      final env = await _env();

      final done = await env.gate.accept({
        ConsentKind.healthData,
        ConsentKind.terms,
        ConsentKind.privacy,
      });

      expect(done, isTrue);
      expect(env.server.posted, [
        {'kind': 'terms', 'version': 1},
        {'kind': 'privacy', 'version': 1},
        {'kind': 'health_data', 'version': 1},
      ]);
      expect(env.server.calls.last, 'GET /v1/me/consents');
      expect(await env.stored(), isEmpty);
      expect(env.harness.syncCalls, 1, reason: 'the paused sync resumes');
      expect(env.state.busy, isFalse);
    });

    test('only terms: the sync was not paused, so nothing resumes', () async {
      final env = await _env(missing: ['terms'], stored: ['terms']);

      expect(await env.gate.accept({ConsentKind.terms}), isTrue);

      expect(await env.stored(), isEmpty);
      expect(env.harness.syncCalls, 0);
    });

    test('a failure in the middle keeps what was recorded and retries the rest',
        () async {
      final env = await _env();
      env.server.postOffline.add('privacy');

      final done = await env.gate.accept({...ConsentKind.baseline});

      expect(done, isFalse);
      expect(env.state.errorCode, 'network_error');
      expect(env.server.accepted, ['terms']);
      expect(await env.stored(), ['health_data', 'privacy']);
      expect(env.harness.syncCalls, 0, reason: 'still paused');

      env.server.postOffline.clear();
      expect(
        await env.gate.accept({ConsentKind.privacy, ConsentKind.healthData}),
        isTrue,
      );
      expect(env.server.accepted, ['terms', 'privacy', 'health_data']);
      expect(await env.stored(), isEmpty);
      expect(env.harness.syncCalls, 1);
    });

    test('if the answer cannot be read after the records, the rest stands in',
        () async {
      final env = await _env();
      env.server.getOffline = true;

      final done = await env.gate.accept({...ConsentKind.baseline});

      expect(done, isTrue, reason: 'every record was accepted');
      expect(await env.stored(), isEmpty);
      expect(env.harness.syncCalls, 1);
    });

    test('a version the server moved on from asks for an app update', () async {
      final env = await _env();
      env.server.current = {...env.server.current, 'terms': 2};

      final done = await env.gate.accept({...ConsentKind.baseline});

      expect(done, isFalse);
      expect(env.state.outdated, isTrue);
      expect(env.state.errorCode, 'consent_outdated');
      expect(env.server.accepted, isEmpty);
      expect(await env.stored(), _all, reason: 'learned from the server');
      expect(env.harness.syncCalls, 0);
    });

    test('too many requests is reported and the gate stays open', () async {
      final env = await _env();
      env.server.postFailures['terms'] = (429, 'rate_limited');

      expect(await env.gate.accept({...ConsentKind.baseline}), isFalse);

      expect(env.state.errorCode, 'rate_limited');
      expect(env.state.busy, isFalse);
      expect(await env.stored(), _all);
    });

    test('a rejected session sends the user back to sign-in', () async {
      final env = await _env();
      env.server.postFailures['terms'] = (401, 'invalid_token');

      expect(await env.gate.accept({...ConsentKind.baseline}), isFalse);

      expect(env.container.read(authSessionProvider).valueOrNull, isFalse);
    });

    test('does nothing without a signed-in account', () async {
      final harness = TestHarness(signedIn: false);
      final container = createContainer(harness);

      final done = await container
          .read(consentGateProvider.notifier)
          .accept({ConsentKind.terms});

      expect(done, isFalse);
      expect(container.read(consentGateProvider).errorCode, 'generic');
    });
  });

  group('refresh', () {
    test('stores the server answer and resumes a paused sync', () async {
      final env = await _env(missing: []);

      await env.gate.refresh();

      expect(await env.stored(), isEmpty);
      expect(env.harness.syncCalls, 1);
    });

    test('a newly missing health consent pauses (no sync)', () async {
      final env = await _env(missing: ['health_data'], stored: []);

      await env.gate.refresh();

      expect(await env.stored(), ['health_data']);
      expect(env.harness.syncCalls, 0);
    });

    test('offline keeps the stored answer', () async {
      final env = await _env();
      env.server.getOffline = true;

      await env.gate.refresh();

      expect(await env.stored(), _all);
      expect(env.harness.syncCalls, 0);
    });

    test('a kind the app has no text for is an update, not a tick box',
        () async {
      final env = await _env(missing: ['marketing'], stored: []);

      await env.gate.refresh();

      expect(await env.stored(), ['marketing']);
      expect(env.state.outdated, isTrue);
    });

    test('asks nothing while signed out', () async {
      final server = FakeConsentServer(missing: _all);
      final harness = TestHarness(signedIn: false, handler: server.handle);
      final container = createContainer(harness);

      await container.read(consentGateProvider.notifier).refresh();

      expect(server.requests, isEmpty);
    });
  });

  test('required follows any missing kind, paused only health data', () async {
    final env = await _env(stored: null);
    env.container.listen(consentRequiredProvider, (_, __) {});
    env.container.listen(medicalSyncPausedProvider, (_, __) {});
    final store = env.container.read(syncStateStoreProvider);
    Future<void> storeKinds(List<String> kinds) async {
      await store.saveConsentMissing(_user, kinds);
      await pumpEventQueue();
    }

    await pumpEventQueue();
    expect(env.container.read(consentRequiredProvider), isFalse,
        reason: 'not asked yet');

    await storeKinds(['terms']);
    expect(env.container.read(consentRequiredProvider), isTrue);
    expect(env.container.read(medicalSyncPausedProvider), isFalse);

    await storeKinds(['privacy', 'health_data']);
    expect(env.container.read(medicalSyncPausedProvider), isTrue);

    await storeKinds([]);
    expect(env.container.read(consentRequiredProvider), isFalse);
    expect(env.container.read(medicalSyncPausedProvider), isFalse);
  });
}
