import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';

void main() {
  testWidgets('sign out asks for confirmation and returns to onboarding',
      (tester) async {
    final requests = <String>[];
    final harness = TestHarness(
      handler: (request) async {
        requests.add(request.url.path);
        return http.Response('', 204);
      },
    );
    final container = createContainer(harness);
    await pumpApp(tester, harness: harness, container: container);
    openRoute(container, AppRoutes.settings);
    await tester.pumpAndSettle();

    expect(find.text('Not synced yet'), findsOneWidget);
    expect(find.text('Default reminders'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reminder-defaults-enabled')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    expect(find.text('Sign out?'), findsOneWidget);

    // Cancel keeps the session.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await harness.tokens.read(), isNotNull);

    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-sign-out')));
    await tester.pumpAndSettle();

    expect(await harness.tokens.read(), isNull);
    expect(requests, contains('/v1/auth/logout'));
    expect(find.byKey(const Key('welcome-register')), findsOneWidget);
    // An explicit sign-out erases the local data: nothing to warn about.
    expect(find.byKey(const Key('session-ended')), findsNothing);
  });

  testWidgets('sign-out with unsent changes warns and offers a sync first',
      (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    await harness.seedMedication(container);
    await pumpApp(tester, harness: harness, container: container);
    openRoute(container, AppRoutes.settings);
    await tester.pumpAndSettle();
    expect(find.text('1 change waiting to be sent'), findsOneWidget);
    final syncsBefore = harness.syncCalls;

    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    expect(
      find.text('1 change has not been sent yet and will be lost.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('sign-out-sync-first')));
    await tester.pumpAndSettle();

    expect(harness.syncCalls, syncsBefore + 1);
    expect(await harness.tokens.read(), isNotNull);
    expect(find.byKey(const Key('sign-out')), findsOneWidget);
  });
}
