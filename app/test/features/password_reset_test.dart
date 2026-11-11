import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/routing/router.dart';

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

const String _email = 'user@example.test';
const String _newPassword = 'a-new-long-password';
const String _requestPath = '/v1/auth/password-reset/request';
const String _confirmPath = '/v1/auth/password-reset/confirm';

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

TextField _field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key)));

/// Requests seen by the fake server, in order: path and decoded body.
class _Server {
  _Server({
    this.request = _accepted,
    this.confirm = _noContent,
    this.login = _notFound,
  });

  static http.Response _accepted() => http.Response('', 202);
  static http.Response _noContent() => http.Response('', 204);
  static http.Response _notFound() => http.Response('', 404);

  final http.Response Function() request;
  final http.Response Function() confirm;
  final http.Response Function() login;
  final List<(String, Map<String, Object?>)> requests = [];

  Future<http.Response> handle(http.Request request) async {
    final body = request.body.isEmpty
        ? <String, Object?>{}
        : jsonDecode(request.body) as Map<String, Object?>;
    requests.add((request.url.path, body));
    return switch (request.url.path) {
      _requestPath => this.request(),
      _confirmPath => confirm(),
      '/v1/auth/login' => login(),
      _ => _notFound(),
    };
  }

  int count(String path) => requests.where((r) => r.$1 == path).length;
}

/// Opens the app signed out, goes to sign-in, types the address and opens
/// «Forgot password?».
Future<ProviderContainer> _openForgot(
  WidgetTester tester,
  _Server server,
) async {
  final container = await pumpApp(
    tester,
    harness: TestHarness(signedIn: false, handler: server.handle),
  );
  await _tap(tester, 'welcome-login');
  await _enter(tester, 'auth-email', 'User@Example.test ');
  await _tap(tester, 'auth-forgot');
  return container;
}

/// Through the request step: the code screen is open.
Future<ProviderContainer> _openReset(
  WidgetTester tester,
  _Server server,
) async {
  final container = await _openForgot(tester, server);
  await _tap(tester, 'forgot-submit');
  return container;
}

Future<void> _confirm(
  WidgetTester tester, {
  String code = '123456',
  String password = _newPassword,
}) async {
  await _enter(tester, 'reset-code', code);
  await _enter(tester, 'auth-password', password);
  await _tap(tester, 'reset-submit');
}

void main() {
  testWidgets('forgot opens with the sign-in address prefilled',
      (tester) async {
    await _openForgot(tester, _Server());

    expect(find.byKey(const Key('forgot-submit')), findsOneWidget);
    expect(_field(tester, 'auth-email').controller?.text, 'User@Example.test ');
  });

  testWidgets('request, code screen, confirm, then the login path',
      (tester) async {
    final server = _Server(login: () => _json(200, _tokens));
    await _openReset(tester, server);

    expect(find.byKey(const Key('reset-code')), findsOneWidget);
    expect(
      find.text('If this address is registered, we sent a code to it.'),
      findsOneWidget,
    );

    await _confirm(tester);

    expect(server.requests.map((r) => r.$1), [
      _requestPath,
      _confirmPath,
      '/v1/auth/login',
      // The sign-in asks which consents the account lacks (ADR 0016 section 5).
      '/v1/me/consents',
    ]);
    expect(server.requests[0].$2, {'email': _email});
    expect(server.requests[1].$2, {
      'email': _email,
      'code': '123456',
      'new_password': _newPassword,
    });
    expect(server.requests[2].$2, {'email': _email, 'password': _newPassword});
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('an accepted request always shows the neutral message',
      (tester) async {
    // The server answers 202 for known and unknown addresses alike; the app
    // must not tell them apart either.
    await _openReset(tester, _Server());

    expect(
      find.text('If this address is registered, we sent a code to it.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('auth-error')), findsNothing);
  });

  testWidgets('a malformed address is refused before any request',
      (tester) async {
    final server = _Server();
    await _openForgot(tester, server);
    await _enter(tester, 'auth-email', 'not-an-address');
    await _tap(tester, 'forgot-submit');

    expect(server.requests, isEmpty);
    expect(find.text('Enter a valid e-mail.'), findsOneWidget);
  });

  testWidgets('rate limiting on the request is explained', (tester) async {
    await _openReset(
      tester,
      _Server(request: () => _error(429, 'rate_limited')),
    );

    expect(
      find.text('Too many attempts. Please wait a minute and try again.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('reset-code')), findsNothing);
  });

  testWidgets('a wrong or expired code is explained, nothing signs in',
      (tester) async {
    final server = _Server(confirm: () => _error(400, 'invalid_code'));
    await _openReset(tester, server);
    await _confirm(tester, code: '000000');

    expect(
      find.text('The code is wrong or expired. Request a new one.'),
      findsOneWidget,
    );
    expect(server.count('/v1/auth/login'), 0);
    expect(find.byKey(const Key('reset-code')), findsOneWidget);
  });

  testWidgets('a weak password is refused before any request', (tester) async {
    final server = _Server();
    await _openReset(tester, server);
    await _confirm(tester, password: 'short');

    expect(server.count(_confirmPath), 0);
    expect(
      find.text('The password must have at least 8 characters.'),
      findsOneWidget,
    );
  });

  testWidgets('a server-side 422 is explained', (tester) async {
    await _openReset(
      tester,
      _Server(confirm: () => _error(422, 'validation_error')),
    );
    await _confirm(tester);

    expect(find.text('Check the entered data.'), findsOneWidget);
  });

  testWidgets('rate limiting on confirm is explained', (tester) async {
    await _openReset(
      tester,
      _Server(confirm: () => _error(429, 'rate_limited')),
    );
    await _confirm(tester);

    expect(
      find.text('Too many attempts. Please wait a minute and try again.'),
      findsOneWidget,
    );
  });

  testWidgets('a code of the wrong shape is refused before any request',
      (tester) async {
    final server = _Server();
    await _openReset(tester, server);
    await _confirm(tester, code: '123');

    expect(server.count(_confirmPath), 0);
    expect(find.byKey(const Key('auth-error')), findsOneWidget);
  });

  testWidgets('resend asks for a new code for the same address',
      (tester) async {
    final server = _Server();
    await _openReset(tester, server);
    await _tap(tester, 'reset-resend');

    expect(server.count(_requestPath), 2);
    expect(server.requests.last.$2, {'email': _email});
    expect(find.text('Code sent again'), findsOneWidget);
  });

  testWidgets('the new password is never prefilled, hidden and autofilled',
      (tester) async {
    await _openReset(tester, _Server());

    final field = _field(tester, 'auth-password');
    expect(field.controller?.text, isEmpty);
    expect(field.obscureText, isTrue);
    expect(field.autofillHints, const [AutofillHints.newPassword]);
    await _tap(tester, 'auth-password-toggle');
    expect(_field(tester, 'auth-password').obscureText, isFalse);
  });

  testWidgets('an account in its deletion grace period goes on to restore',
      (tester) async {
    final server = _Server(
      login: () => _json(403, {
        'error': {
          'code': 'account_pending_deletion',
          'message': 'synthetic',
          'details': {
            'restore_ticket': 'ticket-1',
            'erase_after': '2030-01-20T00:00:00Z',
          },
        },
      }),
    );
    await _openReset(tester, server);
    await _confirm(tester);

    expect(find.byKey(const Key('restore-code')), findsOneWidget);
  });

  testWidgets(
      'a failed sign-in after the change opens sign-in with a notice '
      'and the address', (tester) async {
    final server = _Server(login: () => _error(429, 'rate_limited'));
    await _openReset(tester, server);
    await _confirm(tester);

    expect(find.byKey(const Key('reset-code')), findsNothing);
    expect(
      find.text('Your password was changed. Sign in with the new one.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('auth-error')), findsOneWidget);
    expect(_field(tester, 'auth-email').controller?.text, _email);
    // The new password is never carried over.
    expect(_field(tester, 'auth-password').controller?.text, isEmpty);
  });

  testWidgets('the sign-in form has no notice when opened normally',
      (tester) async {
    await pumpApp(tester, harness: TestHarness(signedIn: false));
    await _tap(tester, 'welcome-login');

    expect(find.byKey(const Key('password-changed')), findsNothing);
  });

  testWidgets('the code screen without an address starts from the forgot step',
      (tester) async {
    final container = await pumpApp(
      tester,
      harness: TestHarness(signedIn: false),
    );
    goRoute(container, AppRoutes.resetPassword);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('forgot-submit')), findsOneWidget);
    expect(find.byKey(const Key('reset-code')), findsNothing);
  });

  testWidgets('forgot: the keyboard done submits the address', (tester) async {
    final server = _Server();
    await _openForgot(tester, server);
    await tester.tap(find.byKey(const Key('auth-email')));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(server.count(_requestPath), 1);
    expect(find.byKey(const Key('reset-code')), findsOneWidget);
  });

  testWidgets('reset: done on the code moves to the new password',
      (tester) async {
    await _openReset(tester, _Server());
    await tester.tap(find.byKey(const Key('reset-code')));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    final password = tester.widget<TextField>(
      find.byKey(const Key('auth-password')),
    );
    expect(password.focusNode?.hasFocus, isTrue);
  });

  testWidgets('the reset screen carries the account for the password manager',
      (tester) async {
    await _openReset(tester, _Server());

    final field = _field(tester, 'reset-email');
    expect(field.readOnly, isTrue);
    expect(field.controller?.text, _email);
    expect(field.autofillHints, const [AutofillHints.username]);
  });

  testWidgets('resend: a second tap within the cooldown sends nothing',
      (tester) async {
    final server = _Server();
    final harness = TestHarness(signedIn: false, handler: server.handle);
    await pumpApp(tester, harness: harness);
    await _tap(tester, 'welcome-login');
    await _enter(tester, 'auth-email', _email);
    await _tap(tester, 'auth-forgot');
    await _tap(tester, 'forgot-submit');

    await _tap(tester, 'reset-resend');
    await _tap(tester, 'reset-resend');
    expect(server.count(_requestPath), 2);

    harness.now = harness.now.add(const Duration(seconds: 31));
    await _tap(tester, 'reset-resend');
    expect(server.count(_requestPath), 3);
  });

  group('the autofill context is committed only by a sign-in', () {
    // The test text input records every platform call.
    Iterable<Object?> commits(WidgetTester tester) => tester.testTextInput.log
        .where((call) => call.method == 'TextInput.finishAutofillContext')
        .map((call) => call.arguments);

    testWidgets('a failed confirm commits nothing', (tester) async {
      final server = _Server(confirm: () => _error(400, 'invalid_code'));
      await _openReset(tester, server);
      await _confirm(tester);

      expect(commits(tester), isNot(contains(true)));
    });

    testWidgets('leaving the screen cancels the context', (tester) async {
      final container = await _openReset(tester, _Server());
      container.read(routerProvider).pop();
      await tester.pumpAndSettle();

      expect(commits(tester), isNot(contains(true)));
    });

    testWidgets('a failed sign-in after the change commits nothing',
        (tester) async {
      final server = _Server(login: () => _error(429, 'rate_limited'));
      await _openReset(tester, server);
      await _confirm(tester);

      expect(commits(tester), isNot(contains(true)));
    });

    testWidgets('a successful sign-in commits or cancels, never half',
        (tester) async {
      final server = _Server(login: () => _json(200, _tokens));
      await _openReset(tester, server);
      await _confirm(tester);

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(commits(tester), isNotEmpty);
    });
  });
}
