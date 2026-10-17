import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

Future<http.Response> _offline(http.Request request) async =>
    http.Response('', 503);

Future<void> _openFamily(WidgetTester tester, TestHarness harness) async {
  final container = createContainer(harness);
  await harness.seedSelfProfile();
  await pumpApp(tester, harness: harness, container: container);
  goRoute(container, AppRoutes.family);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('three sections from the stored links, inactive ones included',
      (tester) async {
    final harness = TestHarness(handler: _offline);
    await seedLink(harness, id: 'out-1', role: 'viewer');
    await seedLink(
      harness,
      id: 'out-2',
      role: 'editor',
      counterpart: 'Blake Relative',
      active: false,
    );
    await seedLink(
      harness,
      id: 'in-1',
      direction: LinkDirection.incoming,
      profileId: 'foreign-profile-1',
      counterpart: 'Grace Owner',
      profileName: 'Grace',
    );
    await seedProfile(
      harness,
      id: 'ward-1',
      kind: 'managed',
      role: 'owner',
      name: 'Pat Ward',
    );
    await _openFamily(tester, harness);

    expect(find.text('Can see me'), findsOneWidget);
    expect(find.text('I can see'), findsOneWidget);
    expect(find.text('People I care for'), findsOneWidget);
    expect(find.text('Alex Relative'), findsOneWidget);
    expect(find.text('Blake Relative'), findsOneWidget);
    // The grant of an account in its deletion grace period is listed and
    // says it is paused; the owner can still open it and revoke.
    expect(find.textContaining('not active'), findsOneWidget);
    expect(find.text('Grace'), findsOneWidget);
    expect(find.text('Pat Ward'), findsOneWidget);
    expect(find.byKey(const Key('invite-self')), findsOneWidget);
    expect(find.byKey(const Key('accept-invite')), findsOneWidget);
    expect(find.byKey(const Key('add-ward')), findsOneWidget);
  });

  testWidgets('a link accepted since the last visit shows a banner, no push',
      (tester) async {
    final harness = TestHarness(handler: _offline);
    final container = createContainer(harness);
    final syncState = container.read(syncStateStoreProvider);
    await syncState.advanceRelativesSeenAt(DateTime.utc(2026, 10, 1));
    await seedLink(
      harness,
      id: 'old',
      counterpart: 'Old Relative',
      createdAt: DateTime.utc(2026, 9, 20),
    );
    await seedLink(
      harness,
      id: 'new',
      counterpart: 'New Relative',
      createdAt: DateTime.utc(2026, 10, 12),
    );
    await harness.seedSelfProfile();
    await pumpApp(tester, harness: harness, container: container);
    goRoute(container, AppRoutes.family);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('new-relative-banner')), findsOneWidget);
    final banner = find.byKey(const Key('new-relative-banner'));
    expect(
      find.descendant(of: banner, matching: find.text('New Relative')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: banner, matching: find.text('Old Relative')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('new-relative-dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('new-relative-banner')), findsNothing);
  });

  testWidgets('an inactive link is never announced as new', (tester) async {
    final harness = TestHarness(handler: _offline);
    final container = createContainer(harness);
    await container
        .read(syncStateStoreProvider)
        .advanceRelativesSeenAt(DateTime.utc(2026, 10, 1));
    await seedLink(
      harness,
      id: 'paused',
      active: false,
      createdAt: DateTime.utc(2026, 10, 12),
    );
    await harness.seedSelfProfile();
    await pumpApp(tester, harness: harness, container: container);
    goRoute(container, AppRoutes.family);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('new-relative-banner')), findsNothing);
    expect(find.byKey(const ValueKey('link-paused')), findsOneWidget);
  });

  testWidgets('a restored relative is announced after the refresh',
      (tester) async {
    final harness = TestHarness(
      handler: (request) async => request.url.path == '/v1/grants'
          ? jsonResponse(
              grantsJson(
                outgoing: [
                  outgoingGrantJson(
                    id: 'out-1',
                    createdAt: '2026-10-05T08:00:00Z',
                  ),
                ],
              ),
            )
          : http.Response('', 503),
    );
    final container = createContainer(harness);
    // The link was paused when last seen, and the baseline is after it.
    await seedLink(harness, id: 'out-1', active: false);
    await container
        .read(syncStateStoreProvider)
        .advanceRelativesSeenAt(DateTime.utc(2026, 10, 11));
    await harness.seedSelfProfile();
    await pumpApp(tester, harness: harness, container: container);
    goRoute(container, AppRoutes.family);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('new-relative-banner')), findsOneWidget);
    expect(find.textContaining('not active'), findsNothing);
  });

  testWidgets('soft limit: no invite button once the limit is reached',
      (tester) async {
    final harness = TestHarness(
      handler: (request) async {
        switch (request.url.path) {
          case '/v1/me/features':
            return jsonResponse({
              'soft_limits_enabled': true,
              'relatives_limit': 1,
              'pdf_reports_limit': 3,
            });
          case '/v1/grants':
            return jsonResponse(
              grantsJson(outgoing: [outgoingGrantJson(id: 'out-1')]),
            );
        }
        return http.Response('', 503);
      },
    );
    await seedLink(harness, id: 'out-1');
    await _openFamily(tester, harness);

    expect(find.byKey(const Key('relatives-limit')), findsOneWidget);
    expect(find.byKey(const Key('invite-self')), findsNothing);
    // Accepting someone else's invite is not limited.
    expect(find.byKey(const Key('accept-invite')), findsOneWidget);
  });

  testWidgets('the limit is ignored while soft limits are off', (tester) async {
    final harness = TestHarness(
      handler: (request) async => request.url.path == '/v1/me/features'
          ? jsonResponse({
              'soft_limits_enabled': false,
              'relatives_limit': 1,
              'pdf_reports_limit': null,
            })
          : http.Response('', 503),
    );
    await seedLink(harness, id: 'out-1');
    await _openFamily(tester, harness);

    expect(find.byKey(const Key('invite-self')), findsOneWidget);
    expect(find.byKey(const Key('relatives-limit')), findsNothing);
  });

  testWidgets('empty account: hint and the three actions', (tester) async {
    await _openFamily(tester, TestHarness(handler: _offline));

    expect(find.textContaining('Share your medication status'), findsOneWidget);
    expect(find.byKey(const Key('invite-self')), findsOneWidget);
    expect(find.byKey(const Key('add-ward')), findsOneWidget);
  });
}
