import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// ADR 0010: deleting the account starts a grace period (at most 30 days, as
// the server states); the login of a pending account offers a restore with
// the e-mailed code.

Map<String, Object> _tokens(String user) => {
      'access_token': fakeAccessToken(userId: user),
      'refresh_token': 'new-refresh',
      'expires_in': 900,
    };

Map<String, Object?> _features({int? graceDays, int? retentionDays}) => {
      'soft_limits_enabled': false,
      'relatives_limit': null,
      'pdf_reports_limit': null,
      'account_deletion_grace_days': graceDays,
      'managed_archive_retention_days': retentionDays,
    };

/// Two managed profiles of the account (one with an active co-guardian, one
/// whose only co-guardian was revoked), an archive and a relative's profile.
Future<void> seedWards(TestHarness harness) async {
  await seedProfile(
    harness,
    id: 'ward-1',
    kind: 'managed',
    role: 'owner',
    name: 'Grandma',
  );
  await seedProfile(
    harness,
    id: 'ward-2',
    kind: 'managed',
    role: 'owner',
    name: 'Grandpa',
  );
  await seedProfile(
    harness,
    id: 'ward-3',
    kind: 'managed',
    role: 'guardian',
    name: 'Old Archive',
    archived: true,
  );
  await seedProfile(harness, id: 'friend-1', name: 'Grace');
  await seedLink(
    harness,
    id: 'guardian-1',
    profileId: 'ward-1',
    role: 'guardian',
    profileKind: 'managed',
  );
  await seedLink(
    harness,
    id: 'guardian-2',
    profileId: 'ward-2',
    role: 'guardian',
    profileKind: 'managed',
    active: false,
  );
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

void main() {
  group('delete account', () {
    Future<(TestHarness, List<String>)> open(
      WidgetTester tester, {
      http.Response? answer,
      Map<String, Object?>? features,
      bool withWards = false,
    }) async {
      final calls = <String>[];
      late final TestHarness harness;
      harness = TestHarness(
        handler: (request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.url.path == '/v1/me/features') {
            return features == null
                ? http.Response('', 503)
                : jsonResponse(features);
          }
          if (request.url.path == '/v1/me' && request.method == 'DELETE') {
            expect(jsonDecode(request.body), {'password': 'right-password'});
            // Unsynced edits are pushed first: the account is gone after.
            calls.add('syncs:${harness.syncCalls}');
            return answer ?? http.Response('', 204);
          }
          return http.Response('', 503);
        },
      );
      final container = createContainer(harness);
      await harness.seedSelfProfile();
      await seedLink(harness, id: 'out-1');
      if (withWards) {
        await seedWards(harness);
      }
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
      await open(tester, withWards: true);

      expect(find.text('Delete account?'), findsOneWidget);
      // The grace period, relatives, managed profiles, notes, the way back.
      expect(find.textContaining('no later than 30 days'), findsOneWidget);
      expect(
        find.textContaining('Relatives lose access to your medications'),
        findsOneWidget,
      );
      expect(find.textContaining('Profiles you manage'), findsOneWidget);
      expect(find.textContaining('co-guardians'), findsWidgets);
      expect(find.textContaining('restore'), findsWidgets);
      expect(find.byKey(const Key('delete-account-password')), findsOneWidget);
    });

    testWidgets('states the grace and retention the server gave',
        (tester) async {
      await open(
        tester,
        withWards: true,
        features: _features(graceDays: 14, retentionDays: 90),
      );

      expect(find.textContaining('no later than 14 days'), findsOneWidget);
      expect(find.textContaining('30 days'), findsNothing);
      expect(
        find.textContaining('kept for 90 days after your account is erased'),
        findsOneWidget,
      );
    });

    testWidgets('names what becomes of each managed profile', (tester) async {
      await open(
        tester,
        withWards: true,
        features: _features(graceDays: 30, retentionDays: 365),
      );

      // Grandma has an active co-guardian: an archive for them.
      expect(
        find.textContaining('Grandma: becomes a read-only archive'),
        findsOneWidget,
      );
      // Grandpa has none, a revoked co-guardian does not count: erased.
      expect(
        find.textContaining('Grandpa: has no co-guardian'),
        findsOneWidget,
      );
      // Archives are not listed again, nor profiles of other people.
      expect(find.textContaining('Old Archive'), findsNothing);
      expect(find.textContaining('Grace'), findsNothing);
    });

    testWidgets('without the retention it says the archive is temporary',
        (tester) async {
      await open(tester, withWards: true);

      expect(
        find.textContaining('Grandma: becomes a read-only archive'),
        findsOneWidget,
      );
      expect(find.textContaining('for a limited time'), findsOneWidget);
    });

    testWidgets('no managed profiles: nothing about them', (tester) async {
      await open(tester);

      expect(find.textContaining('Profiles you manage'), findsNothing);
      expect(find.textContaining('co-guardian'), findsNothing);
    });

    testWidgets('pushes unsynced changes before it deletes', (tester) async {
      final (harness, calls) = await open(tester);
      final before = harness.syncCalls;

      await _enter(tester, 'delete-account-password', 'right-password');
      await tester.tap(find.byKey(const Key('delete-account-confirm')));
      await tester.pumpAndSettle();

      expect(calls, contains('DELETE /v1/me'));
      final atDelete = calls.firstWhere((call) => call.startsWith('syncs:'));
      final count = int.parse(atDelete.substring('syncs:'.length));
      expect(count, greaterThan(before));
    });

    testWidgets('Russian text states the grace period in days', (tester) async {
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
