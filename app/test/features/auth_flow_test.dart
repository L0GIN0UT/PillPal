import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/auth/auth_errors.dart';
import 'package:pillpal/src/features/auth/auth_flow.dart';
import 'package:pillpal/src/features/auth/auth_session.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';

http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

http.Response _error(int status, String code) => _json(status, {
      'error': {'code': code, 'message': 'synthetic'},
    });

final Map<String, Object> _tokens = {
  'access_token': fakeAccessToken(userId: 'user-2'),
  'refresh_token': 'new-refresh',
  'expires_in': 900,
};

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('auth-submit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('register, verify the code and land on Today', (tester) async {
    final requests = <String, Map<String, Object?>>{};
    final harness = TestHarness(
      signedIn: false,
      handler: (request) async {
        requests[request.url.path] =
            jsonDecode(request.body) as Map<String, Object?>;
        switch (request.url.path) {
          case '/v1/auth/register':
            return http.Response('', 202);
          case '/v1/auth/verify-email':
            return _json(200, _tokens);
        }
        return http.Response('', 404);
      },
    );
    await pumpApp(tester, harness: harness, locale: const Locale('ru'));

    // The build serves RU (the default `PILLPAL_REGION`) and the Russian
    // locale suggests it too: no note about the other region.
    expect(
      find.text('Ваши данные будут храниться в: Россия'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('region-other-later')), findsNothing);
    await tester.tap(find.byKey(const Key('welcome-register')));
    await tester.pumpAndSettle();

    await _enter(tester, 'auth-email', 'User@Example.test ');
    await _enter(tester, 'auth-password', 'long-enough-password');
    await _submit(tester);
    expect(find.byKey(const Key('auth-code')), findsOneWidget);
    expect(requests['/v1/auth/register'], {
      'email': 'user@example.test',
      'password': 'long-enough-password',
      'region': 'ru',
      'locale': 'ru',
      'timezone': testZone,
    });

    await _enter(tester, 'auth-code', '123456');
    await _submit(tester);

    expect(find.text('Сегодня'), findsWidgets);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(
      (await harness.tokens.read())?.accessToken,
      fakeAccessToken(userId: 'user-2'),
    );
    expect(requests['/v1/auth/verify-email'], {
      'email': 'user@example.test',
      'code': '123456',
    });
    expect(harness.syncCalls, greaterThan(0));
  });

  testWidgets('the build region is sent; the other one is only explained',
      (tester) async {
    Map<String, Object?>? body;
    final harness = TestHarness(
      signedIn: false,
      handler: (request) async {
        body = jsonDecode(request.body) as Map<String, Object?>;
        return http.Response('', 202);
      },
    );
    // An English device suggests EU, but this build serves RU.
    await pumpApp(tester, harness: harness);

    expect(find.text('Your data will be stored in: Russia'), findsOneWidget);
    expect(find.byKey(const Key('region-other-later')), findsOneWidget);
    expect(find.byKey(const Key('region-eu')), findsNothing);
    await tester.tap(find.byKey(const Key('welcome-register')));
    await tester.pumpAndSettle();
    await _enter(tester, 'auth-email', 'user@example.test');
    await _enter(tester, 'auth-password', 'long-enough-password');
    await _submit(tester);

    expect(body?['region'], 'ru');
    expect(body?['locale'], 'en');
  });

  testWidgets('an EU build registers in EU', (tester) async {
    Map<String, Object?>? body;
    final harness = TestHarness(
      signedIn: false,
      handler: (request) async {
        body = jsonDecode(request.body) as Map<String, Object?>;
        return http.Response('', 202);
      },
    );
    final container = createContainer(
      harness,
      overrides: [
        apiConfigProvider.overrideWithValue(
          ApiConfig(
            baseUrl: Uri.parse('https://eu.example.test'),
            region: 'eu',
          ),
        ),
      ],
    );
    await pumpApp(
      tester,
      harness: harness,
      container: container,
      locale: const Locale('ru'),
    );

    expect(
      find.text('Ваши данные будут храниться в: Европа и другие страны'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('region-other-later')), findsOneWidget);
    await tester.tap(find.byKey(const Key('welcome-register')));
    await tester.pumpAndSettle();
    await _enter(tester, 'auth-email', 'user@example.test');
    await _enter(tester, 'auth-password', 'long-enough-password');
    await _submit(tester);

    expect(body?['region'], 'eu');
  });

  testWidgets('an unknown device zone is not sent', (tester) async {
    Map<String, Object?>? body;
    final harness = TestHarness(
      signedIn: false,
      handler: (request) async {
        body = jsonDecode(request.body) as Map<String, Object?>;
        return http.Response('', 202);
      },
    );
    final container = createContainer(
      harness,
      overrides: [timeZoneReaderProvider.overrideWithValue(() async => null)],
    );
    await pumpApp(tester, harness: harness, container: container);
    await tester.tap(find.byKey(const Key('welcome-register')));
    await tester.pumpAndSettle();
    await _enter(tester, 'auth-email', 'user@example.test');
    await _enter(tester, 'auth-password', 'long-enough-password');
    await _submit(tester);

    expect(body, isNotNull);
    expect(body!.containsKey('timezone'), isFalse);
  });

  testWidgets('client-side validation stops a short password', (tester) async {
    var calls = 0;
    final harness = TestHarness(
      signedIn: false,
      handler: (request) async {
        calls++;
        return http.Response('', 202);
      },
    );
    await pumpApp(tester, harness: harness);
    await tester.tap(find.byKey(const Key('welcome-register')));
    await tester.pumpAndSettle();

    await _enter(tester, 'auth-email', 'user@example.test');
    await _enter(tester, 'auth-password', 'short');
    await _submit(tester);

    expect(
      find.text('The password must have at least 8 characters.'),
      findsOneWidget,
    );
    expect(calls, 0);
  });

  Future<void> loginWith(
    WidgetTester tester,
    Future<http.Response> Function(http.Request) handler,
  ) async {
    await pumpApp(
      tester,
      harness: TestHarness(signedIn: false, handler: handler),
    );
    await tester.tap(find.byKey(const Key('welcome-login')));
    await tester.pumpAndSettle();
    await _enter(tester, 'auth-email', 'user@example.test');
    await _enter(tester, 'auth-password', 'some-password');
    await _submit(tester);
  }

  testWidgets('wrong credentials are explained', (tester) async {
    await loginWith(tester, (r) async => _error(401, 'invalid_credentials'));
    expect(find.text('Wrong e-mail or password.'), findsOneWidget);
  });

  testWidgets('rate limiting is explained', (tester) async {
    await loginWith(tester, (r) async => _error(429, 'rate_limited'));
    expect(
      find.text('Too many attempts. Please wait a minute and try again.'),
      findsOneWidget,
    );
  });

  testWidgets('a network failure is explained', (tester) async {
    await loginWith(
      tester,
      (r) async => throw http.ClientException('offline'),
    );
    expect(
      find.text('No connection to the server. Check the internet and try '
          'again.'),
      findsOneWidget,
    );
  });

  testWidgets('an unverified address leads to the code screen', (tester) async {
    await loginWith(tester, (request) async {
      if (request.url.path == '/v1/auth/login') {
        return _error(403, 'email_not_verified');
      }
      return http.Response('', 202); // resend
    });
    expect(find.byKey(const Key('auth-code')), findsOneWidget);
  });

  testWidgets('a successful login opens Today', (tester) async {
    await loginWith(tester, (r) async => _json(200, _tokens));
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('signed-in users cannot reach login or registration',
      (tester) async {
    final container = await pumpApp(tester);

    for (final route in [
      AppRoutes.login,
      AppRoutes.register,
      AppRoutes.verify,
      AppRoutes.welcome,
    ]) {
      goRoute(container, route);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('auth-email')), findsNothing);
      expect(find.byKey(const Key('welcome-register')), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
    }
  });

  testWidgets('after a forced sign-out the kept data is explained',
      (tester) async {
    final harness = TestHarness(signedIn: false);
    final container = createContainer(harness);
    // A revoked session leaves the data bound to its account.
    await container.read(syncStateStoreProvider).bindAccount('user-1', 'ru');
    await pumpApp(tester, harness: harness, container: container);

    expect(find.byKey(const Key('session-ended')), findsOneWidget);
    await tester.tap(find.byKey(const Key('welcome-login')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('other-account-warning')), findsOneWidget);
  });

  testWidgets('a fresh device shows no data warnings', (tester) async {
    await pumpApp(tester, harness: TestHarness(signedIn: false));

    expect(find.byKey(const Key('session-ended')), findsNothing);
    await tester.tap(find.byKey(const Key('welcome-login')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('other-account-warning')), findsNothing);
  });

  test('error codes map to messages, unknown codes to a generic one', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final codes = {
      'invalid_credentials': l10n.errorInvalidCredentials,
      'email_not_verified': l10n.errorEmailNotVerified,
      'invalid_code': l10n.errorInvalidCode,
      'rate_limited': l10n.errorRateLimited,
      'wrong_region': l10n.errorWrongRegion,
      'validation_error': l10n.errorValidation,
      ApiException.networkError: l10n.errorNetwork,
      AuthClientErrors.invalidEmail: l10n.errorInvalidEmail,
      'something_new': l10n.errorGeneric,
    };
    for (final entry in codes.entries) {
      expect(authErrorMessage(l10n, entry.key), entry.value);
    }
  });

  test('region suggestion follows the device language', () {
    expect(DataRegion.suggestedFor(const Locale('ru')), DataRegion.ru);
    expect(DataRegion.suggestedFor(const Locale('de')), DataRegion.eu);
    expect(DataRegion.fromWire('eu'), DataRegion.eu);
    expect(DataRegion.fromWire('ru'), DataRegion.ru);
  });

  test('router redirect gates the app on the session', () {
    expect(
      authRedirect(signedIn: null, location: AppRoutes.today),
      AppRoutes.loading,
    );
    expect(
      authRedirect(signedIn: false, location: AppRoutes.today),
      AppRoutes.welcome,
    );
    expect(authRedirect(signedIn: false, location: AppRoutes.login), isNull);
    expect(
      authRedirect(signedIn: true, location: AppRoutes.verify),
      AppRoutes.today,
    );
    expect(authRedirect(signedIn: true, location: AppRoutes.history), isNull);
  });
}
