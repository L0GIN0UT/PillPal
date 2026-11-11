import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/settings/account_section.dart';
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

const String _requestPath = '/v1/auth/password-change/request';
const String _confirmPath = '/v1/auth/password-change/confirm';
const String _current = 'the-current-password';
const String _new = 'a-new-long-password';

/// A fake server for the change: `/v1/me` plus the two endpoints.
class _Server {
  _Server({
    this.hasPassword = true,
    this.request = _accepted,
    this.confirm = _noContent,
  });

  static http.Response _accepted() => http.Response('', 202);
  static http.Response _noContent() => http.Response('', 204);

  final bool hasPassword;
  final http.Response Function() request;
  final http.Response Function() confirm;
  final List<(String, Map<String, Object?>)> requests = [];

  Future<http.Response> handle(http.Request req) async {
    final body = req.body.isEmpty
        ? <String, Object?>{}
        : jsonDecode(req.body) as Map<String, Object?>;
    requests.add((req.url.path, body));
    return switch (req.url.path) {
      '/v1/me' => _json(200, {
          'id': 'user-1',
          'email': 'user@example.test',
          'email_verified': true,
          'has_password': hasPassword,
          'region': 'ru',
          'locale': 'en',
          'created_at': '2026-10-16T08:00:00Z',
        }),
      _requestPath => request(),
      _confirmPath => confirm(),
      _ => _error(404, 'not_found'),
    };
  }

  List<Map<String, Object?>> bodiesOf(String path) => [
        for (final (p, body) in requests)
          if (p == path) body,
      ];
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

String _text(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

/// Settings is open; the row is tapped; step 1 shows.
Future<(ProviderContainer, TestHarness)> _openScreen(
  WidgetTester tester,
  _Server server,
) async {
  final harness = TestHarness(handler: server.handle);
  final container = createContainer(harness);
  await pumpApp(tester, harness: harness, container: container);
  openRoute(container, AppRoutes.settings);
  await tester.pumpAndSettle();
  await _tap(tester, 'settings-change-password');
  return (container, harness);
}

/// Through step 1: the code step shows.
Future<(ProviderContainer, TestHarness)> _openCodeStep(
  WidgetTester tester,
  _Server server,
) async {
  final opened = await _openScreen(tester, server);
  await _enter(tester, 'change-password-current', _current);
  await _tap(tester, 'change-password-next');
  return opened;
}

Future<void> _background(WidgetTester tester) async {
  // Frames stop while the app is paused: come back to look at the screen.
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await tester.pump();
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
}

void main() {
  group('entry', () {
    testWidgets('Settings lists the row for an account with a password', (
      tester,
    ) async {
      final harness = TestHarness(handler: _Server().handle);
      final container = createContainer(harness);
      await pumpApp(tester, harness: harness, container: container);
      openRoute(container, AppRoutes.settings);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-change-password')), findsOneWidget);
    });

    testWidgets('the row is hidden for an account without a password', (
      tester,
    ) async {
      final harness = TestHarness(handler: _Server(hasPassword: false).handle);
      final container = createContainer(harness);
      await pumpApp(tester, harness: harness, container: container);
      openRoute(container, AppRoutes.settings);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-change-password')), findsNothing);
      expect(find.byKey(const Key('sign-out')), findsOneWidget);
    });

    testWidgets('the row shows while the account is unknown (offline)', (
      tester,
    ) async {
      final harness = TestHarness();
      final container = createContainer(harness);
      await pumpApp(tester, harness: harness, container: container);
      openRoute(container, AppRoutes.settings);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-change-password')), findsOneWidget);
    });
  });

  group('flow', () {
    testWidgets('step 1 asks for the current password only', (tester) async {
      await _openScreen(tester, _Server());

      expect(find.byKey(const Key('change-password-current')), findsOneWidget);
      expect(find.byKey(const Key('change-password-next')), findsOneWidget);
      expect(find.byKey(const Key('change-password-code')), findsNothing);
    });

    testWidgets('a right password opens step 2; saving returns to Settings', (
      tester,
    ) async {
      final server = _Server();
      final (_, harness) = await _openScreen(tester, server);
      final tokensBefore = await harness.tokens.read();

      await _enter(tester, 'change-password-current', _current);
      await _tap(tester, 'change-password-next');

      expect(server.bodiesOf(_requestPath), [
        {'current_password': _current},
      ]);
      expect(find.byKey(const Key('change-password-code')), findsOneWidget);
      expect(find.byKey(const Key('change-password-new')), findsOneWidget);
      expect(find.byKey(const Key('change-password-resend')), findsOneWidget);
      expect(find.byKey(const Key('change-password-current')), findsNothing);

      await _enter(tester, 'change-password-code', '123456');
      await _enter(tester, 'change-password-new', _new);
      await _tap(tester, 'change-password-submit');

      expect(server.bodiesOf(_confirmPath), [
        {'code': '123456', 'new_password': _new},
      ]);
      // Back on Settings, with the notice; the session is untouched.
      expect(find.byKey(const Key('change-password-done')), findsOneWidget);
      expect(find.byKey(const Key('settings-change-password')), findsOneWidget);
      final tokensAfter = await harness.tokens.read();
      expect(tokensAfter?.refreshToken, tokensBefore?.refreshToken);
      expect(tokensAfter?.accessToken, tokensBefore?.accessToken);
    });

    testWidgets('a wrong current password is shown and keeps step 1', (
      tester,
    ) async {
      final server = _Server(request: () => _error(401, 'invalid_password'));
      await _openScreen(tester, server);

      await _enter(tester, 'change-password-current', 'wrong');
      await _tap(tester, 'change-password-next');

      expect(find.text('Wrong password.'), findsOneWidget);
      expect(find.byKey(const Key('change-password-current')), findsOneWidget);
      expect(find.byKey(const Key('change-password-code')), findsNothing);
      expect(
        [
          for (final (path, _) in server.requests) path,
        ].where((path) => path == '/v1/auth/refresh'),
        isEmpty,
      );
    });

    testWidgets('a wrong code is shown and keeps step 2', (tester) async {
      final server = _Server(confirm: () => _error(400, 'invalid_code'));
      await _openCodeStep(tester, server);

      await _enter(tester, 'change-password-code', '123456');
      await _enter(tester, 'change-password-new', _new);
      await _tap(tester, 'change-password-submit');

      expect(find.byKey(const Key('auth-error')), findsOneWidget);
      expect(find.byKey(const Key('change-password-code')), findsOneWidget);
      // One refusal is not yet a reason to point at the reset.
      expect(find.byKey(const Key('change-password-forgot')), findsNothing);
    });

    testWidgets('a short new password is refused without a request', (
      tester,
    ) async {
      final server = _Server();
      await _openCodeStep(tester, server);

      await _enter(tester, 'change-password-code', '123456');
      await _enter(tester, 'change-password-new', 'short');
      await _tap(tester, 'change-password-submit');

      expect(server.bodiesOf(_confirmPath), isEmpty);
      expect(find.byKey(const Key('auth-error')), findsOneWidget);
    });

    testWidgets('resend mails another code with the same password', (
      tester,
    ) async {
      final server = _Server();
      await _openCodeStep(tester, server);

      await _tap(tester, 'change-password-resend');

      expect(server.bodiesOf(_requestPath), [
        {'current_password': _current},
        {'current_password': _current},
      ]);
      expect(find.byKey(const Key('change-password-code')), findsOneWidget);
    });
  });

  group('the current password in memory', () {
    testWidgets('going to the background clears step 1', (tester) async {
      await _openScreen(tester, _Server());
      await _enter(tester, 'change-password-current', _current);

      await _background(tester);

      expect(_text(tester, 'change-password-current'), isEmpty);
    });

    testWidgets('after the background, resend returns to step 1 with a note', (
      tester,
    ) async {
      final server = _Server();
      await _openCodeStep(tester, server);

      await _background(tester);
      // The mailed code is still good: step 2 stays until a resend needs the
      // password.
      expect(find.byKey(const Key('change-password-code')), findsOneWidget);

      await _tap(tester, 'change-password-resend');

      expect(server.bodiesOf(_requestPath), hasLength(1));
      expect(find.byKey(const Key('change-password-current')), findsOneWidget);
      expect(_text(tester, 'change-password-current'), isEmpty);
      expect(find.textContaining('cleared the password'), findsOneWidget);
    });

    testWidgets('the code still works after the background', (tester) async {
      final server = _Server();
      await _openCodeStep(tester, server);
      await _background(tester);

      await _enter(tester, 'change-password-code', '123456');
      await _enter(tester, 'change-password-new', _new);
      await _tap(tester, 'change-password-submit');

      expect(server.bodiesOf(_confirmPath), hasLength(1));
      expect(find.byKey(const Key('change-password-done')), findsOneWidget);
    });

    testWidgets(
      'closing the screen wipes it, and a new visit starts at step 1',
      (tester) async {
        final server = _Server();
        await _openCodeStep(tester, server);

        await tester.pageBack();
        await tester.pumpAndSettle();
        await _tap(tester, 'settings-change-password');

        expect(
          find.byKey(const Key('change-password-current')),
          findsOneWidget,
        );
        expect(_text(tester, 'change-password-current'), isEmpty);
        expect(find.byKey(const Key('change-password-code')), findsNothing);
      },
    );
  });

  group('forgot password', () {
    testWidgets('is offered after repeated refusals and leads to sign-out', (
      tester,
    ) async {
      final server = _Server(confirm: () => _error(400, 'invalid_code'));
      final (_, harness) = await _openCodeStep(tester, server);

      for (final code in ['123456', '123457']) {
        await _enter(tester, 'change-password-code', code);
        await _enter(tester, 'change-password-new', _new);
        await _tap(tester, 'change-password-submit');
      }
      expect(find.byKey(const Key('change-password-forgot')), findsOneWidget);

      await _tap(tester, 'change-password-forgot');
      expect(find.byKey(const Key('confirm-sign-out')), findsOneWidget);
      // The reset flow belongs to the sign-in screen.
      await _tap(tester, 'confirm-sign-out');

      expect(await harness.tokens.read(), isNull);
      expect(find.byKey(const Key('welcome-login')), findsOneWidget);
    });

    testWidgets('can be dismissed without leaving the account', (tester) async {
      final server = _Server(confirm: () => _error(400, 'invalid_code'));
      final (_, harness) = await _openCodeStep(tester, server);
      for (final code in ['123456', '123457']) {
        await _enter(tester, 'change-password-code', code);
        await _enter(tester, 'change-password-new', _new);
        await _tap(tester, 'change-password-submit');
      }

      await _tap(tester, 'change-password-forgot');
      await _tap(tester, 'sign-out-cancel');

      expect(await harness.tokens.read(), isNotNull);
      expect(find.byKey(const Key('change-password-code')), findsOneWidget);
    });
  });

  group('step 1', () {
    testWidgets('a quiet Forgot password is always there', (tester) async {
      await _openScreen(tester, _Server());

      expect(find.byKey(const Key('change-password-forgot')), findsOneWidget);
    });

    testWidgets('it leads to a sign-out that keeps the local data',
        (tester) async {
      final harness = TestHarness(handler: _Server().handle);
      final container = createContainer(harness);
      await harness.seedSelfProfile();
      await harness.seedMedication(container);
      await pumpApp(tester, harness: harness, container: container);
      openRoute(container, AppRoutes.settings);
      await tester.pumpAndSettle();
      await _tap(tester, 'settings-change-password');
      expect(
        await container.read(pendingChangesProvider.future),
        greaterThan(0),
      );

      await _tap(tester, 'change-password-forgot');
      // Nothing is lost, so no warning and no "sync first".
      expect(find.byKey(const Key('sign-out-sync-first')), findsNothing);
      expect(find.text('Cannot change the password?'), findsOneWidget);
      await _tap(tester, 'confirm-sign-out');

      expect(await harness.tokens.read(), isNull);
      expect(find.byKey(const Key('welcome-login')), findsOneWidget);
      expect(
        await container.read(pendingChangesProvider.future),
        greaterThan(0),
        reason: 'the outbox stays for the next sign-in',
      );
    });

    testWidgets('an empty password gets its own message', (tester) async {
      final server = _Server();
      await _openScreen(tester, server);

      await _tap(tester, 'change-password-next');

      expect(find.text('Enter your current password.'), findsOneWidget);
      expect(server.bodiesOf(_requestPath), isEmpty);
    });

    testWidgets('the background clears the field and says so', (tester) async {
      await _openScreen(tester, _Server());
      await _enter(tester, 'change-password-current', _current);

      await _background(tester);

      expect(_text(tester, 'change-password-current'), isEmpty);
      expect(find.textContaining('cleared the password'), findsOneWidget);
    });

    testWidgets('inactive alone (Face ID, autofill) keeps what is typed',
        (tester) async {
      await _openScreen(tester, _Server());
      await _enter(tester, 'change-password-current', _current);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(_text(tester, 'change-password-current'), _current);
    });
  });

  group('step 2 address', () {
    testWidgets('shows the masked e-mail when Settings knows it',
        (tester) async {
      await _openCodeStep(tester, _Server());

      expect(find.textContaining('u•••@example.test'), findsOneWidget);
    });

    testWidgets('omits it when the account is unknown (offline)',
        (tester) async {
      final harness = TestHarness(
        handler: (request) async => switch (request.url.path) {
          _requestPath => http.Response('', 202),
          _ => http.Response('', 503),
        },
      );
      final container = createContainer(harness);
      await pumpApp(tester, harness: harness, container: container);
      openRoute(container, AppRoutes.settings);
      await tester.pumpAndSettle();
      await _tap(tester, 'settings-change-password');
      await _enter(tester, 'change-password-current', _current);
      await _tap(tester, 'change-password-next');

      expect(find.textContaining('your e-mail'), findsOneWidget);
      expect(find.textContaining('•••'), findsNothing);
    });
  });
}
