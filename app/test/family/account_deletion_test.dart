import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// ADR 0010: deleting the account starts a 30-day grace period; the login of
// a pending account offers a restore with the e-mailed code.

Map<String, Object> _tokens(String user) => {
      'access_token': fakeAccessToken(userId: user),
      'refresh_token': 'new-refresh',
      'expires_in': 900,
    };

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

void main() {
  group('delete account', () {
    Future<(TestHarness, List<String>)> open(
      WidgetTester tester, {
      http.Response? answer,
    }) async {
      final calls = <String>[];
      final harness = TestHarness(
        handler: (request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.url.path == '/v1/me' && request.method == 'DELETE') {
            expect(jsonDecode(request.body), {'password': 'right-password'});
            return answer ?? http.Response('', 204);
          }
          return http.Response('', 503);
        },
      );
      final container = createContainer(harness);
      await harness.seedSelfProfile();
      await seedLink(harness, id: 'out-1');
      await pumpApp(tester, harness: harness, container: container);
      openRoute(container, AppRoutes.settings);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('delete-account')));
      await tester.tap(find.byKey(const Key('delete-account')));
      await tester.pumpAndSettle();
      return (harness, calls);
    }

    testWidgets('the dialog states every consequence before asking',
        (tester) async {
      await open(tester);

      expect(find.text('Delete account?'), findsOneWidget);
      // The grace period, relatives, managed profiles, notes, the way back.
      expect(find.textContaining('30 days'), findsOneWidget);
      expect(
        find.textContaining('Relatives lose access to your medications'),
        findsOneWidget,
      );
      expect(find.textContaining('Profiles you manage'), findsOneWidget);
      expect(find.textContaining('co-guardians'), findsWidgets);
      expect(find.textContaining('restore'), findsWidgets);
      expect(find.byKey(const Key('delete-account-password')), findsOneWidget);
    });

    testWidgets('Russian text states the grace period in days',
        (tester) async {
      final harness = TestHarness();
      final container = createContainer(harness);
      await harness.seedSelfProfile();
      await pumpApp(
        tester,
        harness: harness,
        container: container,
        locale: const Locale('ru'),
      );
      openRoute(container, AppRoutes.settings);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('delete-account')));
      await tester.tap(find.byKey(const Key('delete-account')));
      await tester.pumpAndSettle();

      expect(find.textContaining('30 дней'), findsOneWidget);
    });

    testWidgets('cancel changes nothing', (tester) async {
      final (harness, calls) = await open(tester);

      await tester.tap(find.byKey(const Key('delete-account-cancel')));
      await tester.pumpAndSettle();

      expect(find.text('Delete account?'), findsNothing);
      expect(calls, isNot(contains('DELETE /v1/me')));
      expect(await harness.tokens.read(), isNotNull);
    });

    testWidgets('a wrong password stays in the dialog, with no refresh',
        (tester) async {
      final (harness, calls) = await open(
        tester,
        answer: errorResponse(401, 'invalid_password'),
      );

      await _enter(tester, 'delete-account-password', 'right-password');
      await tester.tap(find.byKey(const Key('delete-account-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('delete-account-error')), findsOneWidget);
      expect(find.text('Wrong password.'), findsOneWidget);
      expect(find.text('Delete account?'), findsOneWidget);
      expect(calls.where((c) => c.contains('refresh')), isEmpty);
      expect(await harness.tokens.read(), isNotNull);
      final links = await harness.db.select(harness.db.relativeLinks).get();
      expect(links, isNotEmpty);
    });

    testWidgets('success signs out and wipes this phone', (tester) async {
      final (harness, calls) = await open(tester);

      await _enter(tester, 'delete-account-password', 'right-password');
      await tester.tap(find.byKey(const Key('delete-account-confirm')));
      await tester.pumpAndSettle();

      expect(calls, contains('DELETE /v1/me'));
      // The server revoked every session: no logout call, tokens forgotten.
      expect(calls, isNot(contains('POST /v1/auth/logout')));
      expect(await harness.tokens.read(), isNull);
      expect(find.byKey(const Key('welcome-register')), findsOneWidget);
      expect(await harness.db.select(harness.db.profiles).get(), isEmpty);
      expect(await harness.db.select(harness.db.relativeLinks).get(), isEmpty);
    });
  });

  group('restore', () {
    final pending = errorResponse(
      403,
      'account_pending_deletion',
      details: {
        'restore_ticket': 'ticket-secret',
        'erase_after': '2026-11-10T08:00:00Z',
      },
    );

    Future<({TestHarness harness, List<http.Request> requests})> open(
      WidgetTester tester, {
      http.Response? restoreAnswer,
    }) async {
      final requests = <http.Request>[];
      final harness = TestHarness(
        signedIn: false,
        handler: (request) async {
          requests.add(request);
          switch (request.url.path) {
            case '/v1/auth/login':
              return pending;
            case '/v1/auth/restore':
              return restoreAnswer ?? jsonResponse(_tokens('user-1'));
          }
          return http.Response('', 503);
        },
      );
      await pumpApp(tester, harness: harness);
      await tester.tap(find.byKey(const Key('welcome-login')));
      await tester.pumpAndSettle();
      await _enter(tester, 'auth-email', 'user@example.test');
      await _enter(tester, 'auth-password', 'long-enough-password');
      await tester.tap(find.byKey(const Key('auth-submit')));
      await tester.pumpAndSettle();
      return (harness: harness, requests: requests);
    }

    testWidgets('login of a pending account leads to the restore screen',
        (tester) async {
      await open(tester);

      expect(find.byKey(const Key('restore-code')), findsOneWidget);
      expect(find.textContaining('November 10'), findsOneWidget);
      expect(find.textContaining('user@example.test'), findsOneWidget);
      // The ticket is a secret of the app's memory: never on screen.
      expect(find.textContaining('ticket-secret'), findsNothing);
    });

    testWidgets('the ticket and the mailed code restore and sign in',
        (tester) async {
      final run = await open(tester);

      await _enter(tester, 'restore-code', '123456');
      await tester.tap(find.byKey(const Key('restore-submit')));
      await tester.pumpAndSettle();

      final restore =
          run.requests.lastWhere((r) => r.url.path == '/v1/auth/restore');
      expect(jsonDecode(restore.body), {
        'restore_ticket': 'ticket-secret',
        'code': '123456',
      });
      expect(await run.harness.tokens.read(), isNotNull);
      // Signed in: the onboarding is gone and the tabs are there.
      expect(find.byKey(const Key('restore-code')), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(run.harness.syncCalls, greaterThan(0));
    });

    testWidgets('a malformed code is refused before any request',
        (tester) async {
      final run = await open(tester);
      final before = run.requests.length;

      await _enter(tester, 'restore-code', '12');
      await tester.tap(find.byKey(const Key('restore-submit')));
      await tester.pumpAndSettle();

      expect(run.requests.length, before);
      expect(find.text('Enter the 6-digit code.'), findsOneWidget);
    });

    testWidgets('a wrong or expired code is explained', (tester) async {
      final run = await open(
        tester,
        restoreAnswer: errorResponse(404, 'invalid_token'),
      );

      await _enter(tester, 'restore-code', '123456');
      await tester.tap(find.byKey(const Key('restore-submit')));
      await tester.pumpAndSettle();

      expect(find.textContaining('wrong or has expired'), findsOneWidget);
      expect(await run.harness.tokens.read(), isNull);
      expect(find.byKey(const Key('restore-code')), findsOneWidget);
    });
  });
}
