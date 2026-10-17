import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/features/auth/auth_session.dart';
import 'package:pillpal/src/features/family/relatives_scope.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// Synthetic token (a bearer secret in real life).
const String _token = 'abcdefghijklmnopqrstuvwxyz012345';
final Uri _link = Uri.parse('https://links-ru.pillpal.invalid/i#$_token');

Widget _withScope(Widget app) => RelativesScope(child: app);

class _Run {
  _Run(this.harness);

  final TestHarness harness;
  final List<String> calls = [];
}

_Run _newRun({bool signedIn = true}) {
  late final _Run run;
  run = _Run(
    TestHarness(
      signedIn: signedIn,
      handler: (request) async {
        run.calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/v1/invites/preview') {
          return jsonResponse({
            'inviter_display_name': 'Grace Owner',
            'profile_display_name': 'Grace',
            'profile_kind': 'self',
            'role': 'viewer',
            'expires_at': '2026-10-23T08:00:00Z',
          });
        }
        return http.Response('', 503);
      },
    ),
  );
  return run;
}

void main() {
  testWidgets('a link that arrives while the app runs opens the preview',
      (tester) async {
    final run = _newRun();
    await run.harness.seedSelfProfile();
    await pumpApp(tester, harness: run.harness, wrap: _withScope);

    run.harness.links.emit(_link);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invite-preview-title')), findsOneWidget);
    // Opening is not accepting.
    expect(run.calls, contains('POST /v1/invites/preview'));
    expect(run.calls, isNot(contains('POST /v1/invites/accept')));
    expect(find.byKey(const Key('accept-confirm')), findsOneWidget);
  });

  testWidgets('the link that started the app opens the preview',
      (tester) async {
    final run = _newRun();
    run.harness.links.initial = _link;
    await run.harness.seedSelfProfile();
    await pumpApp(tester, harness: run.harness, wrap: _withScope);

    expect(find.byKey(const Key('invite-preview-title')), findsOneWidget);
    expect(run.calls.where((c) => c.endsWith('/preview')), hasLength(1));
  });

  testWidgets('the launch link replayed on the stream is handled once',
      (tester) async {
    final run = _newRun();
    run.harness.links.initial = _link;
    await run.harness.seedSelfProfile();
    await pumpApp(tester, harness: run.harness, wrap: _withScope);
    await tester.tap(find.byKey(const Key('accept-decline')));
    await tester.pumpAndSettle();

    run.harness.links.emit(_link);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invite-preview-title')), findsNothing);
    expect(run.calls.where((c) => c.endsWith('/preview')), hasLength(1));
  });

  testWidgets('a link of another host is shown as a problem, never sent',
      (tester) async {
    final run = _newRun();
    await run.harness.seedSelfProfile();
    await pumpApp(tester, harness: run.harness, wrap: _withScope);

    run.harness.links.emit(Uri.parse('https://evil.example/i#$_token'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('accept-problem')), findsOneWidget);
    expect(run.calls.where((c) => c.contains('/invites/')), isEmpty);
  });

  testWidgets('a link opened while signed out waits for the sign-in',
      (tester) async {
    final run = _newRun(signedIn: false);
    final container =
        await pumpApp(tester, harness: run.harness, wrap: _withScope);

    run.harness.links.emit(_link);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('welcome-register')), findsOneWidget);
    expect(run.calls, isEmpty);

    await run.harness.tokens.write(
      TokenPair(
        accessToken: fakeAccessToken(),
        refreshToken: 'refresh',
        accessExpiresAt: DateTime.utc(2100),
      ),
    );
    container.read(authSessionProvider.notifier).markSignedIn();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invite-preview-title')), findsOneWidget);
    expect(run.calls, contains('POST /v1/invites/preview'));
  });
}
