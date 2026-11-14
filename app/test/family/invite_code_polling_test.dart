import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/family/invite_timing.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'add_relative_support.dart';
import 'family_fixtures.dart';
import 'invite_server.dart';

// The invite QR panel's polling and its races (docs/adr/0020 §2): what each
// state of the invite does, errors that do not stop it, a paused app or a
// covered screen, and role changes while a request is in flight.

void main() {
  for (final entry in {
    'revoked': (FakeInviteServer server) => server.state = 'revoked',
    'expired': (FakeInviteServer server) => server.state = 'expired',
    'gone (404)': (FakeInviteServer server) =>
        server.statusAnswer = errorResponse(404, 'not_found'),
  }.entries) {
    testWidgets('a code the server reports ${entry.key} shows the expired view',
        (tester) async {
      final run = await openAddRelative(tester);
      await showCode(tester);

      entry.value(run.server);
      await tester.pump(InviteTiming.poll);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('invite-qr')), findsNothing);
      expect(find.byKey(const Key('invite-expired')), findsOneWidget);
      expect(find.byKey(const Key('invite-refresh')), findsOneWidget);
      final polls = run.server.polled.length;
      await tester.pump(InviteTiming.poll * 2);
      expect(run.server.polled, hasLength(polls));
      // Gone already: leaving revokes nothing.
      await tapKey(tester, 'add-relative-done');
      expect(run.server.revoked, isEmpty);
    });
  }

  testWidgets('a server error or no network keeps the code and the polling',
      (tester) async {
    final run = await openAddRelative(tester);
    await showCode(tester);

    run.server.statusAnswer = errorResponse(500, 'internal');
    await tester.pump(InviteTiming.poll);
    await tester.pump(InviteTiming.poll);
    run.server
      ..statusAnswer = null
      ..statusOffline = true;
    await tester.pump(InviteTiming.poll);
    await tester.pumpAndSettle();

    expect(run.server.polled.length, greaterThanOrEqualTo(3));
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);

    run.server
      ..statusOffline = false
      ..state = 'consumed'
      ..outgoing = [outgoingGrantJson(id: 'out-new', grantee: 'Мария')];
    await tester.pump(InviteTiming.poll);
    await tester.pumpAndSettle();
    expect(find.text('Мария is now one of your relatives'), findsOneWidget);
  });

  testWidgets('a paused app does not poll and asks at once on return',
      (tester) async {
    final run = await openAddRelative(tester);
    await showCode(tester);
    // The listener checks each step, as a real app goes through them.
    void go(List<AppLifecycleState> states) {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    go(const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);
    await tester.pump();
    final polls = run.server.polled.length;
    await tester.pump(InviteTiming.poll * 3);
    expect(run.server.polled, hasLength(polls));

    go(const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    await tester.pump();
    expect(run.server.polled, hasLength(polls + 1));
  });

  testWidgets('a covered screen does not poll and asks at once on return',
      (tester) async {
    final run = await openAddRelative(tester);
    await showCode(tester);

    openRoute(run.container, AppRoutes.settings);
    await tester.pumpAndSettle();
    final polls = run.server.polled.length;
    await tester.pump(InviteTiming.poll * 3);
    expect(run.server.polled, hasLength(polls));

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(run.server.polled.length, greaterThan(polls));
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
  });

  testWidgets('a role change while the code is being made revokes it',
      (tester) async {
    final gate = Completer<void>();
    final server = FakeInviteServer()..createGate = gate;
    final run = await openAddRelative(tester, server: server);
    await tapKey(tester, 'add-relative-show-code', settle: false);
    await tester.pump();
    expect(find.byKey(const Key('invite-creating')), findsOneWidget);

    await tapKey(tester, 'add-relative-editor', settle: false);
    gate.complete();
    await tester.pumpAndSettle();

    // The code that arrived after the change is never shown and is revoked.
    expect(run.server.revoked, [run.server.created.single['id']]);
    expect(find.byKey(const Key('invite-qr')), findsNothing);
    expect(find.byKey(const Key('add-relative-show-code')), findsOneWidget);
    expect(roleBoxEnabled(tester), isTrue);
  });

  testWidgets('the role cannot change while an acceptance is announced',
      (tester) async {
    final gate = Completer<void>();
    final run = await openAddRelative(tester);
    await showCode(tester);
    expect(roleBoxEnabled(tester), isTrue);

    run.server
      ..grantsGate = gate
      ..state = 'consumed'
      ..outgoing = [outgoingGrantJson(id: 'out-new', grantee: 'Мария')];
    await tester.pump(InviteTiming.poll);
    await tester.pump();

    expect(roleBoxEnabled(tester), isFalse);
    await tester.tap(find.byKey(const Key('add-relative-editor')));
    await tester.pump();
    expect(run.server.revoked, isEmpty);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Мария is now one of your relatives'), findsOneWidget);
    // The used code is not revoked when the screen goes.
    await tapKey(tester, 'relative-added-done');
    expect(run.server.revoked, isEmpty);
  });
}
