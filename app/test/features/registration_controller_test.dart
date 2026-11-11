import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/auth/auth_errors.dart';
import 'package:pillpal/src/features/auth/auth_flow.dart';
import 'package:pillpal/src/features/auth/auth_session.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';

// The registration controller and its route guards (ADR 0016 §3): credentials
// held between step 1 and step 2, nothing sent before the consents.

http.Response _error(int status, String code) => http.Response(
      jsonEncode({
        'error': {'code': code, 'message': 'synthetic'},
      }),
      status,
      headers: {'content-type': 'application/json'},
    );

/// The three consents of the baseline at version 1, as the server wants them.
const List<Map<String, Object?>> _baselineConsents = [
  {'kind': 'terms', 'version': 1},
  {'kind': 'privacy', 'version': 1},
  {'kind': 'health_data', 'version': 1},
];

Future<void> _fillCredentials(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('welcome-register')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('auth-email')),
    'user@example.test',
  );
  await tester.enterText(
    find.byKey(const Key('auth-password')),
    'long-enough-password',
  );
  await tester.tap(find.byKey(const Key('auth-submit')));
  await tester.pumpAndSettle();
}

void main() {
  group('registration controller', () {
    Future<({ProviderContainer container, List<http.Request> requests})>
        setUpFlow({
      Future<http.Response> Function(http.Request)? answer,
      List<Override> overrides = const [],
    }) async {
      final requests = <http.Request>[];
      final harness = TestHarness(
        signedIn: false,
        handler: (request) async {
          requests.add(request);
          return answer == null ? http.Response('', 202) : answer(request);
        },
      );
      final container = createContainer(harness, overrides: overrides);
      // The stored session is read once; its arrival restarts the flow.
      await container.read(authSessionProvider.future);
      return (container: container, requests: requests);
    }

    AuthFlowController flow(ProviderContainer container) =>
        container.read(authFlowProvider.notifier);

    test('the steps are 1, 2 and 3 of 3', () {
      expect(RegistrationStep.credentials.number, 1);
      expect(RegistrationStep.consent.number, 2);
      expect(RegistrationStep.code.number, 3);
      expect(RegistrationStep.total, 3);
    });

    test('continuing makes no request and holds the credentials', () async {
      final env = await setUpFlow();
      final ok = flow(env.container).continueRegistration(
        email: ' User@Example.test ',
        password: 'long-enough-password',
      );

      expect(ok, isTrue);
      expect(env.requests, isEmpty);
      final state = env.container.read(authFlowProvider);
      // The address is not published to the flows that read `email` (password
      // reset, the code screens) before the account exists.
      expect(state.email, isNull);
      expect(state.credentialsHeld, isTrue);
      expect(state.registering, isTrue);
      expect(state.errorCode, isNull);
    });

    test('continuing validates the credentials locally', () async {
      final env = await setUpFlow();
      expect(
        flow(
          env.container,
        ).continueRegistration(email: 'nope', password: 'long-enough-password'),
        isFalse,
      );
      expect(
        env.container.read(authFlowProvider).errorCode,
        AuthClientErrors.invalidEmail,
      );
      expect(
        flow(
          env.container,
        ).continueRegistration(email: 'user@example.test', password: 'short'),
        isFalse,
      );
      final state = env.container.read(authFlowProvider);
      expect(state.errorCode, AuthClientErrors.passwordTooShort);
      expect(state.credentialsHeld, isFalse);
      expect(env.requests, isEmpty);
    });

    for (final region in ['ru', 'eu']) {
      test('registering in $region sends exactly the three consents', () async {
        final env = await setUpFlow(
          overrides: [
            apiConfigProvider.overrideWithValue(
              ApiConfig(
                baseUrl: Uri.parse('https://$region.example.test'),
                region: region,
              ),
            ),
          ],
        );
        flow(env.container).continueRegistration(
          email: 'user@example.test',
          password: 'long-enough-password',
        );
        final sent = await flow(env.container).register(locale: 'ru');

        expect(sent, isTrue);
        expect(env.requests, hasLength(1));
        final body =
            jsonDecode(env.requests.single.body) as Map<String, Object?>;
        expect(body['region'], region);
        expect(body['consents'], _baselineConsents);
        final state = env.container.read(authFlowProvider);
        expect(state.email, 'user@example.test');
        expect(state.registering, isTrue);
      });
    }

    test('abandoning drops the credentials and nothing can be sent', () async {
      final env = await setUpFlow();
      flow(env.container).continueRegistration(
        email: 'user@example.test',
        password: 'long-enough-password',
      );
      flow(env.container).abandonRegistration();

      final state = env.container.read(authFlowProvider);
      expect(state.credentialsHeld, isFalse);
      expect(state.registering, isFalse);
      expect(state.email, isNull);
      expect(await flow(env.container).register(locale: 'en'), isFalse);
      expect(env.requests, isEmpty);
    });

    test('abandoning after the request keeps the code step', () async {
      final env = await setUpFlow();
      flow(env.container).continueRegistration(
        email: 'user@example.test',
        password: 'long-enough-password',
      );
      await flow(env.container).register(locale: 'en');
      flow(env.container).abandonRegistration();

      final state = env.container.read(authFlowProvider);
      expect(state.email, 'user@example.test');
      expect(state.registering, isTrue);
    });

    test('a password reset request ends the registration', () async {
      final env = await setUpFlow();
      flow(env.container).continueRegistration(
        email: 'user@example.test',
        password: 'long-enough-password',
      );
      await flow(env.container).requestPasswordReset('other@example.test');

      final state = env.container.read(authFlowProvider);
      expect(state.credentialsHeld, isFalse);
      expect(state.registering, isFalse);
      expect(state.email, 'other@example.test');
      expect(await flow(env.container).register(locale: 'en'), isFalse);
    });

    test('without stored credentials nothing is sent', () async {
      final env = await setUpFlow();
      final sent = await flow(env.container).register(locale: 'en');

      expect(sent, isFalse);
      expect(env.requests, isEmpty);
      expect(
        env.container.read(authFlowProvider).errorCode,
        AuthClientErrors.generic,
      );
    });

    test('the password is wiped after a successful registration', () async {
      final env = await setUpFlow();
      flow(env.container).continueRegistration(
        email: 'user@example.test',
        password: 'long-enough-password',
      );
      expect(await flow(env.container).register(locale: 'en'), isTrue);
      expect(env.container.read(authFlowProvider).credentialsHeld, isFalse);

      // A second attempt has nothing to send: the password is gone.
      expect(await flow(env.container).register(locale: 'en'), isFalse);
      expect(env.requests, hasLength(1));
    });

    test('a failed registration keeps the credentials for a retry', () async {
      var attempts = 0;
      final env = await setUpFlow(
        answer: (request) async => ++attempts == 1
            ? _error(429, 'rate_limited')
            : http.Response('', 202),
      );
      flow(env.container).continueRegistration(
        email: 'user@example.test',
        password: 'long-enough-password',
      );
      expect(await flow(env.container).register(locale: 'en'), isFalse);
      expect(env.container.read(authFlowProvider).errorCode, 'rate_limited');
      expect(env.container.read(authFlowProvider).credentialsHeld, isTrue);
      expect(await flow(env.container).register(locale: 'en'), isTrue);
    });

    test('the password is wiped when the session changes', () async {
      final env = await setUpFlow();
      flow(env.container).continueRegistration(
        email: 'user@example.test',
        password: 'long-enough-password',
      );
      env.container.read(authSessionProvider.notifier).markSignedIn();
      await env.container
          .read(authSessionProvider.notifier)
          .signOutKeepingData();

      expect(env.container.read(authFlowProvider).credentialsHeld, isFalse);
      expect(await flow(env.container).register(locale: 'en'), isFalse);
      expect(env.requests, isEmpty);
    });

    for (final code in ['unsupported_consent_version', 'consent_required']) {
      test('$code asks for an app update', () async {
        final env =
            await setUpFlow(answer: (request) async => _error(422, code));
        flow(env.container).continueRegistration(
          email: 'user@example.test',
          password: 'long-enough-password',
        );

        expect(await flow(env.container).register(locale: 'en'), isFalse);
        expect(
          env.container.read(authFlowProvider).errorCode,
          AuthClientErrors.consentOutdated,
        );
        final l10n = lookupAppLocalizations(const Locale('en'));
        expect(
          authErrorMessage(l10n, AuthClientErrors.consentOutdated),
          l10n.errorConsentOutdated,
        );
      });
    }

    test('a login that needs a code is not a registration step', () async {
      final env = await setUpFlow(
        answer: (request) async => request.url.path == '/v1/auth/login'
            ? _error(403, 'email_not_verified')
            : http.Response('', 202),
      );
      flow(env.container).continueRegistration(
        email: 'user@example.test',
        password: 'long-enough-password',
      );
      final outcome = await flow(
        env.container,
      ).login(email: 'user@example.test', password: 'long-enough-password');

      expect(outcome, LoginOutcome.needsVerification);
      final state = env.container.read(authFlowProvider);
      expect(state.registering, isFalse);
      expect(state.credentialsHeld, isFalse);
    });
  });

  testWidgets('without a pending registration the consent step is skipped', (
    tester,
  ) async {
    final container = await pumpApp(
      tester,
      harness: TestHarness(signedIn: false),
    );
    goRoute(container, AppRoutes.registerConsent);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('consent-submit')), findsNothing);
    expect(find.byKey(const Key('auth-email')), findsOneWidget);
  });

  testWidgets('back from the consent step drops the held credentials',
      (tester) async {
    final container = await pumpApp(
      tester,
      harness: TestHarness(signedIn: false),
    );
    await _fillCredentials(tester);
    expect(container.read(authFlowProvider).credentialsHeld, isTrue);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(container.read(authFlowProvider).credentialsHeld, isFalse);

    // A deep link to the step finds no credentials and starts from the form.
    goRoute(container, AppRoutes.registerConsent);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('consent-submit')), findsNothing);
    expect(find.byKey(const Key('auth-email')), findsOneWidget);
  });

  testWidgets('an unfinished registration does not open the reset code step',
      (tester) async {
    final container = await pumpApp(
      tester,
      harness: TestHarness(signedIn: false),
    );
    container.read(authFlowProvider.notifier).continueRegistration(
          email: 'user@example.test',
          password: 'long-enough-password',
        );
    goRoute(container, AppRoutes.resetPassword);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('auth-email')), findsOneWidget);
    expect(find.byKey(const Key('auth-code')), findsNothing);
  });

  testWidgets('back from the code step reaches the form and can go on',
      (tester) async {
    await pumpApp(
      tester,
      harness: TestHarness(
        signedIn: false,
        handler: (request) async => http.Response('', 202),
      ),
    );
    await _fillCredentials(tester);
    for (final key in ['consent-terms', 'consent-privacy', 'consent-health']) {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.tap(find.byKey(Key(key)));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('consent-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('auth-code')), findsOneWidget);

    // The account exists; the form below offers a new attempt, which the
    // server answers the same way (no enumeration).
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('auth-password')), findsOneWidget);
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('consent-submit')), findsOneWidget);
  });
}
