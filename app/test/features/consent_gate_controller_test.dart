import 'dart:async';

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
        // The one that lifts the sync pause goes first.
        {'kind': 'health_data', 'version': 1},
        {'kind': 'terms', 'version': 1},
        {'kind': 'privacy', 'version': 1},
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
      expect(env.server.accepted, ['health_data', 'terms']);
      expect(await env.stored(), ['privacy']);
      expect(env.harness.syncCalls, 1, reason: 'health data is there: resume');

      env.server.postOffline.clear();
      expect(await env.gate.accept({ConsentKind.privacy}), isTrue);
      expect(env.server.accepted, ['health_data', 'terms', 'privacy']);
      expect(await env.stored(), isEmpty);
      expect(env.harness.syncCalls, 1, reason: 'nothing left to resume');
    });

    test('accepting the new text removes an outdated item, no resume needed',
        () async {
      final env = await _env(
        missing: ['health_data'],
        stored: ['~health_data'],
      );

      expect(await env.gate.accept({ConsentKind.healthData}), isTrue);

      expect(await env.stored(), isEmpty);
      expect(env.harness.syncCalls, 0, reason: 'the sync was never paused');
    });

    test('a failure after the health consent was recorded resumes the sync',
        () async {
      final env = await _env();
      env.server.postFailures['terms'] = (503, 'unavailable');

      expect(await env.gate.accept({...ConsentKind.baseline}), isFalse);

      expect(await env.stored(), ['terms', 'privacy']);
      expect(env.harness.syncCalls, 1);
    });

    test('a request while another is in flight is refused without an error',
        () async {
      final env = await _env();
      env.server.holdPosts = Completer<void>();

      final first = env.gate.accept({...ConsentKind.baseline});
      await pumpEventQueue();
      expect(env.state.busy, isTrue);
      final second = await env.gate.accept({...ConsentKind.baseline});

      expect(second, isFalse);
      expect(env.state.errorCode, isNull);
      env.server.holdPosts!.complete();
      expect(await first, isTrue);
      expect(env.server.accepted, hasLength(3));
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
      expect(env.server.accepted, ['health_data'], reason: 'recorded first');
      expect(await env.stored(), ['terms', 'privacy']);
      expect(env.harness.syncCalls, 1, reason: 'health data is there');
    });

    test('too many requests waits for Retry-After before sending again',
        () async {
      final env = await _env();
      env.server.postFailures['health_data'] = (429, 'rate_limited');
      env.server.retryAfterSeconds = 45;

      expect(await env.gate.accept({...ConsentKind.baseline}), isFalse);

      expect(env.state.errorCode, 'rate_limited');
      expect(env.state.busy, isFalse);
      expect(
        env.state.retryUntil,
        env.harness.now.add(const Duration(seconds: 45)),
      );
      expect(await env.stored(), _all);

      env.server.postFailures.clear();
      final posts = env.server.posted.length;
      expect(await env.gate.accept({...ConsentKind.baseline}), isFalse);
      expect(env.server.posted, hasLength(posts), reason: 'still waiting');

      env.harness.now = env.harness.now.add(const Duration(seconds: 46));
      expect(await env.gate.accept({...ConsentKind.baseline}), isTrue);
    });

    test('without Retry-After a default wait applies, capped when huge',
        () async {
      final env = await _env();
      env.server.postFailures['health_data'] = (429, 'rate_limited');

      await env.gate.accept({...ConsentKind.baseline});
      expect(
        env.state.retryUntil,
        env.harness.now.add(ConsentGateController.defaultRetryDelay),
      );

      env.harness.now = env.harness.now.add(const Duration(minutes: 5));
      env.server.retryAfterSeconds = 86400;
      await env.gate.accept({...ConsentKind.baseline});
      expect(
        env.state.retryUntil,
        env.harness.now.add(ConsentGateController.maxRetryDelay),
      );
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

    test('an answer that began before the consents were recorded is dropped',
        () async {
      final env = await _env();
      final slow = Completer<void>();
      env.server.holdNextGet = slow;

      final refresh = env.gate.refresh();
      await pumpEventQueue();
      expect(await env.gate.accept({...ConsentKind.baseline}), isTrue);
      expect(await env.stored(), isEmpty);
      slow.complete();
      await refresh;

      expect(await env.stored(), isEmpty, reason: 'the stale answer lost');
      expect(env.state.checking, isFalse);
    });

    test('while checking the state says so, and not afterwards', () async {
      final env = await _env();
      final slow = Completer<void>();
      env.server.holdNextGet = slow;

      final refresh = env.gate.refresh();
      expect(env.state.checking, isTrue);
      slow.complete();
      await refresh;

      expect(env.state.checking, isFalse);
    });

    test('asks nothing while signed out', () async {
      final server = FakeConsentServer(missing: _all);
      final harness = TestHarness(signedIn: false, handler: server.handle);
      final container = createContainer(harness);

      await container.read(consentGateProvider.notifier).refresh();

      expect(server.requests, isEmpty);
    });
  });

  test('an outdated health text is required but does not pause', () async {
    final env = await _env(stored: null);
    env.container.listen(consentRequiredProvider, (_, __) {});
    env.container.listen(medicalSyncPausedProvider, (_, __) {});
    await env.container
        .read(syncStateStoreProvider)
        .saveConsentMissing(_user, ['~health_data']);
    await pumpEventQueue();

    expect(env.container.read(consentRequiredProvider), isTrue);
    expect(env.container.read(medicalSyncPausedProvider), isFalse);
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
