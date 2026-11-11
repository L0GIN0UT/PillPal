import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/settings/delete_account_dialog.dart';
import 'package:pillpal/src/routing/router.dart';

import '../helpers.dart';
import '../support/consent_server.dart';

// The re-consent gate (ADR 0016 §5): routing, the screen that lists only what
// is missing, and the exits.

const String _user = 'user-1';
const List<String> _all = ['health_data', 'terms', 'privacy'];

AppLocalizations get _en => lookupAppLocalizations(const Locale('en'));

String _location(ProviderContainer container) =>
    container.read(routerProvider).routerDelegate.currentConfiguration.uri.path;

class _Gate {
  _Gate(this.server, this.harness, this.container);

  final FakeConsentServer server;
  final TestHarness harness;
  final ProviderContainer container;
}

/// Opens the app signed in, with [stored] as the answer already on the
/// device; the server says the same unless [serverMissing] is given.
Future<_Gate> _pump(
  WidgetTester tester, {
  List<String> stored = _all,
  List<String>? serverMissing,
  List<Map<String, Object?>> records = const [],
}) async {
  final server = FakeConsentServer(missing: serverMissing ?? stored)
    ..records = [...records];
  final harness = TestHarness(handler: server.handle);
  final container = createContainer(harness);
  final store = container.read(syncStateStoreProvider);
  await store.bindAccount(_user, 'ru');
  await store.saveConsentMissing(_user, stored);
  await pumpApp(tester, harness: harness, container: container);
  return _Gate(server, harness, container);
}

Future<void> _tick(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pump();
}

bool _submitEnabled(WidgetTester tester) {
  final button = find.descendant(
    of: find.byKey(const Key('consent-gate-submit')),
    matching: find.byType(FilledButton),
  );
  return tester.widget<FilledButton>(button).onPressed != null;
}

void main() {
  group('authRedirect', () {
    String? redirect(
      String location, {
      bool? signedIn = true,
      bool consent = false,
    }) =>
        authRedirect(
          signedIn: signedIn,
          location: location,
          consentRequired: consent,
        );

    test('while consents are missing every location leads to the gate', () {
      for (final location in [
        AppRoutes.today,
        AppRoutes.settings,
        AppRoutes.acceptInvite,
        AppRoutes.family,
        '/medication/m1',
        AppRoutes.welcome,
        AppRoutes.loading,
      ]) {
        expect(
          redirect(location, consent: true),
          AppRoutes.consentGate,
          reason: location,
        );
      }
      expect(redirect(AppRoutes.consentGate, consent: true), isNull);
    });

    test('with nothing missing the gate leads to Today, the rest is as before',
        () {
      expect(redirect(AppRoutes.consentGate), AppRoutes.today);
      expect(redirect(AppRoutes.today), isNull);
      expect(redirect(AppRoutes.welcome), AppRoutes.today);
    });

    test('an unknown answer holds the loading screen, signed in only', () {
      expect(
        authRedirect(
          signedIn: true,
          location: AppRoutes.today,
          consentPending: true,
        ),
        AppRoutes.loading,
      );
      expect(
        authRedirect(
          signedIn: true,
          location: AppRoutes.loading,
          consentPending: true,
        ),
        isNull,
      );
      expect(
        authRedirect(
          signedIn: false,
          location: AppRoutes.welcome,
          consentPending: true,
        ),
        isNull,
      );
      // Once known, the loading screen leaves for the right place.
      expect(redirect(AppRoutes.loading), AppRoutes.today);
      expect(redirect(AppRoutes.loading, consent: true), AppRoutes.consentGate);
    });

    test('signed out or still loading ignore the consent state', () {
      expect(
        redirect(AppRoutes.consentGate, signedIn: false, consent: true),
        AppRoutes.welcome,
      );
      expect(
        redirect(AppRoutes.today, signedIn: null, consent: true),
        AppRoutes.loading,
      );
      expect(
        redirect(AppRoutes.welcome, signedIn: false, consent: true),
        isNull,
      );
    });
  });

  testWidgets('an account lacking consents sees the gate, and nothing else',
      (tester) async {
    final gate = await _pump(tester);

    expect(_location(gate.container), AppRoutes.consentGate);
    expect(find.byKey(const Key('consent-gate-submit')), findsOneWidget);
    for (final target in [
      AppRoutes.settings,
      AppRoutes.acceptInvite,
      '/medication/m1',
      AppRoutes.family,
    ]) {
      goRoute(gate.container, target);
      await tester.pumpAndSettle();
      expect(_location(gate.container), AppRoutes.consentGate, reason: target);
    }
  });

  testWidgets('lists only the missing items; health data says sync is paused',
      (tester) async {
    await _pump(tester, stored: ['terms']);

    expect(find.byKey(const Key('consent-terms')), findsOneWidget);
    expect(find.byKey(const Key('consent-privacy')), findsNothing);
    expect(find.byKey(const Key('consent-health')), findsNothing);
    expect(find.byKey(const Key('consent-gate-paused')), findsNothing);
  });

  testWidgets('a missing health data consent shows its card and the notice',
      (tester) async {
    await _pump(tester, stored: ['health_data']);

    expect(find.byKey(const Key('consent-health-card')), findsOneWidget);
    expect(find.byKey(const Key('consent-health-version')), findsOneWidget);
    expect(find.byKey(const Key('consent-terms')), findsNothing);
    expect(find.text(_en.consentGatePaused), findsOneWidget);
  });

  testWidgets('an outdated health text shows the gate without the notice',
      (tester) async {
    final gate = await _pump(
      tester,
      stored: ['~health_data'],
      serverMissing: ['health_data'],
      records: [consentRecord('health_data')],
    );

    expect(_location(gate.container), AppRoutes.consentGate);
    expect(find.byKey(const Key('consent-health')), findsOneWidget);
    expect(find.byKey(const Key('consent-gate-paused')), findsNothing,
        reason: 'the sync is not paused');
  });

  testWidgets('the button waits for every shown item; nothing is pre-ticked',
      (tester) async {
    await _pump(tester);

    expect(_submitEnabled(tester), isFalse);
    expect(find.byKey(const Key('consent-gate-hint')), findsOneWidget);
    await _tick(tester, 'consent-terms');
    await _tick(tester, 'consent-privacy');
    expect(_submitEnabled(tester), isFalse);
    await _tick(tester, 'consent-health');
    expect(_submitEnabled(tester), isTrue);
    expect(find.byKey(const Key('consent-gate-hint')), findsNothing);
  });

  testWidgets('accepting records the items, resumes the sync and opens Today',
      (tester) async {
    final gate = await _pump(tester);
    for (final key in ['consent-terms', 'consent-privacy', 'consent-health']) {
      await _tick(tester, key);
    }
    final syncsBefore = gate.harness.syncCalls;

    await tester.tap(find.byKey(const Key('consent-gate-submit')));
    await tester.pumpAndSettle();

    expect(gate.server.accepted, ['health_data', 'terms', 'privacy']);
    expect(find.byKey(const Key('consent-gate-submit')), findsNothing);
    expect(_location(gate.container), AppRoutes.today);
    // The gate resumes it, and Today asks for one when it opens.
    expect(gate.harness.syncCalls, greaterThan(syncsBefore));
  });

  testWidgets('a failure shows the error and a retry sends only the rest',
      (tester) async {
    final gate = await _pump(tester);
    gate.server.postOffline.add('privacy');
    for (final key in ['consent-terms', 'consent-privacy', 'consent-health']) {
      await _tick(tester, key);
    }

    await tester.tap(find.byKey(const Key('consent-gate-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('auth-error')), findsOneWidget);
    expect(find.text(_en.errorNetwork), findsOneWidget);
    expect(find.byKey(const Key('consent-terms')), findsNothing,
        reason: 'recorded: no longer asked');
    expect(find.byKey(const Key('consent-privacy')), findsOneWidget);
    expect(_location(gate.container), AppRoutes.consentGate);

    gate.server.postOffline.clear();
    await tester.tap(find.byKey(const Key('consent-gate-submit')));
    await tester.pumpAndSettle();

    expect(gate.server.accepted, ['health_data', 'terms', 'privacy']);
    expect(gate.server.posted.where((p) => p['kind'] == 'terms'), hasLength(1));
    expect(_location(gate.container), AppRoutes.today);
  });

  testWidgets('a server ahead of the app blocks, and "check again" rechecks',
      (tester) async {
    final gate = await _pump(tester);
    gate.server.current = {...gate.server.current, 'privacy': 2};
    for (final key in ['consent-terms', 'consent-privacy', 'consent-health']) {
      await _tick(tester, key);
    }

    await tester.tap(find.byKey(const Key('consent-gate-submit')));
    await tester.pumpAndSettle();

    // The blocked layout: why, no way to continue, a recheck and the exits.
    expect(find.text(_en.consentBlockedTitle), findsOneWidget);
    expect(find.text(_en.consentBlockedBody), findsOneWidget);
    expect(find.byKey(const Key('consent-gate-submit')), findsNothing);
    expect(find.byKey(const Key('consent-privacy')), findsNothing);
    expect(find.byKey(const Key('consent-gate-recheck')), findsOneWidget);
    expect(find.byKey(const Key('consent-gate-sign-out')), findsOneWidget);
    expect(find.byKey(const Key('consent-gate-delete')), findsOneWidget);
    expect(_location(gate.container), AppRoutes.consentGate);

    // Still ahead: checking again changes nothing.
    await tester.tap(find.byKey(const Key('consent-gate-recheck')));
    await tester.pumpAndSettle();
    expect(find.text(_en.consentBlockedTitle), findsOneWidget);

    // The versions meet again: the list of what is missing comes back.
    gate.server.current = {...gate.server.current, 'privacy': 1};
    await tester.tap(find.byKey(const Key('consent-gate-recheck')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('consent-privacy')), findsOneWidget);
    expect(find.byKey(const Key('consent-gate-recheck')), findsNothing);
  });

  testWidgets('a kind the app has no text for is the blocked layout too',
      (tester) async {
    await _pump(tester, stored: ['marketing']);

    expect(find.text(_en.consentBlockedTitle), findsOneWidget);
    expect(find.byKey(const Key('consent-gate-submit')), findsNothing);
  });

  testWidgets('the deletion dialog is one of the exits', (tester) async {
    await _pump(tester);

    await tester.ensureVisible(find.byKey(const Key('consent-gate-delete')));
    await tester.tap(find.byKey(const Key('consent-gate-delete')));
    await tester.pumpAndSettle();

    expect(find.byType(DeleteAccountDialog), findsOneWidget);
  });

  Future<_Gate> pumpWithPausedChanges(WidgetTester tester) async {
    final server = FakeConsentServer(missing: _all);
    final harness = TestHarness(handler: server.handle);
    final container = createContainer(harness);
    final store = container.read(syncStateStoreProvider);
    await store.bindAccount(_user, 'ru');
    await store.saveConsentMissing(_user, _all);
    await harness.seedSelfProfile();
    await harness.seedMedication(container);
    await pumpApp(tester, harness: harness, container: container);
    server.requests.clear();
    await tester.ensureVisible(find.byKey(const Key('consent-gate-sign-out')));
    await tester.tap(find.byKey(const Key('consent-gate-sign-out')));
    await tester.pumpAndSettle();
    return _Gate(server, harness, container);
  }

  testWidgets('signing out of the gate keeps the paused changes by default',
      (tester) async {
    final gate = await pumpWithPausedChanges(tester);

    expect(find.textContaining(_en.signOutPausedKeepBody), findsOneWidget);
    expect(find.textContaining(_en.signOutPausedBody(1)), findsOneWidget);
    expect(find.byKey(const Key('sign-out-sync-first')), findsNothing);
    expect(find.byKey(const Key('sign-out-erase')), findsOneWidget);

    await tester.tap(find.byKey(const Key('confirm-sign-out')));
    await tester.pumpAndSettle();

    expect(await gate.harness.tokens.read(), isNull);
    expect(find.byKey(const Key('welcome-register')), findsOneWidget);
    expect(
      gate.server.calls.where((call) => call.contains('/v1/sync')),
      isEmpty,
      reason: 'the flush before the sign-out is paused too',
    );
    final store = gate.container.read(syncStateStoreProvider);
    expect(await store.boundUserId(), _user, reason: 'data stays bound');
    expect(
      await gate.harness.db.select(gate.harness.db.outbox).get(),
      isNotEmpty,
      reason: 'the same account sends it after signing in and consenting',
    );
  });

  testWidgets('"sign out and erase" wipes the device, the destructive choice',
      (tester) async {
    final gate = await pumpWithPausedChanges(tester);

    await tester.tap(find.byKey(const Key('sign-out-erase')));
    await tester.pumpAndSettle();

    expect(await gate.harness.tokens.read(), isNull);
    expect(find.byKey(const Key('welcome-register')), findsOneWidget);
    final store = gate.container.read(syncStateStoreProvider);
    expect(await store.consentMissing(), isNull);
    expect(await store.boundUserId(), isNull);
    expect(
      await gate.harness.db.select(gate.harness.db.outbox).get(),
      isEmpty,
    );
  });

  testWidgets('at start the server answer replaces the stored one',
      (tester) async {
    final gate =
        await _pump(tester, stored: [], serverMissing: ['health_data']);

    expect(_location(gate.container), AppRoutes.consentGate);
    expect(find.byKey(const Key('consent-health')), findsOneWidget);
    expect(
      await gate.container.read(syncStateStoreProvider).consentMissing(),
      ['health_data'],
    );
  });

  testWidgets('a sign-in forgets the answer of the session before it',
      (tester) async {
    final harness = TestHarness(
      signedIn: false,
      handler: (request) async => http.Response(
        jsonEncode({
          'access_token': fakeAccessToken(userId: _user),
          'refresh_token': 'new-refresh',
          'expires_in': 900,
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final container = createContainer(harness);
    final store = container.read(syncStateStoreProvider);
    // A forced sign-out left the data bound, with the answer of that session.
    await store.bindAccount(_user, 'ru');
    await store.saveConsentMissing(_user, ['health_data']);
    await pumpApp(tester, harness: harness, container: container);

    await tester.tap(find.byKey(const Key('welcome-login')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('auth-email')), 'a@example.test');
    await tester.enterText(
        find.byKey(const Key('auth-password')), 'some-password');
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();

    expect(await store.consentMissing(), isNull, reason: 'asked again');
    expect(_location(container), AppRoutes.today);
  });

  testWidgets('without a sign-in the gate is never reached', (tester) async {
    final harness = TestHarness(signedIn: false);
    final container = createContainer(harness);
    await pumpApp(tester, harness: harness, container: container);

    expect(find.byKey(const Key('welcome-register')), findsOneWidget);
    expect(find.byKey(const Key('consent-gate-submit')), findsNothing);
  });
}
