import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/family/invite_timing.dart';
import 'package:pillpal/src/links/link_providers.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'family_fixtures.dart';
import 'invite_server.dart';

// Invites to a managed profile (a co-guardian, an observer or a helper):
// the role and the disclosure, then the same QR panel as «Добавить близкого»
// (countdown, renewal, share, the news when the code is accepted).

Future<({FakeInviteServer server, List<String> shared})> _open(
  WidgetTester tester, {
  required String profileId,
  FakeInviteServer? server,
  String role = 'owner',
  String kind = 'self',
  bool archived = false,
}) async {
  final fake = server ?? FakeInviteServer();
  final harness = TestHarness(handler: fake.handle);
  final shared = <String>[];
  final container = createContainer(
    harness,
    overrides: [
      textSharerProvider.overrideWithValue((text) async => shared.add(text)),
    ],
  );
  await harness.seedSelfProfile();
  if (profileId != selfProfileId) {
    await seedProfile(
      harness,
      id: profileId,
      kind: kind,
      role: role,
      archived: archived,
    );
  }
  await pumpApp(tester, harness: harness, container: container);
  openRoute(container, AppRoutes.createInvite(profileId));
  await tester.pumpAndSettle();
  return (server: fake, shared: shared);
}

Future<void> _create(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('invite-create')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'managed profile: guardian with its own disclosure, then the QR '
      'panel', (tester) async {
    final run = await _open(tester, profileId: 'ward-1', kind: 'managed');

    expect(find.byKey(const ValueKey('invite-role-viewer')), findsOneWidget);
    expect(find.byKey(const ValueKey('invite-role-editor')), findsOneWidget);
    expect(find.byKey(const ValueKey('invite-role-guardian')), findsOneWidget);
    // A managed profile has no phone of its own to disclose: its name and
    // time zone are what a relative sees.
    expect(find.textContaining('Your name, time zone'), findsNothing);
    expect(
      find.textContaining('name of this profile and its time zone'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('invite-role-guardian')));
    await tester.pump();
    expect(
      find.textContaining('A guardian sees everything about this profile'),
      findsOneWidget,
    );
    expect(find.textContaining('"Only me" ones, notes'), findsOneWidget);
    expect(find.textContaining('Medications set to "Family"'), findsNothing);
    // Nothing is created before the confirmation.
    expect(run.server.created, isEmpty);

    await _create(tester);

    expect(run.server.log.first, 'POST /v1/profiles/ward-1/invites');
    expect(run.server.created.single['role'], 'guardian');
    expect(run.server.created.single['disclosure_version'], 1);
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
    expect(find.byKey(const Key('invite-countdown')), findsOneWidget);
    expect(find.textContaining('links-ru.pillpal.invalid'), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('invite-share')));
    await tester.tap(find.byKey(const Key('invite-share')));
    await tester.pump();
    expect(run.shared.single, contains(inviteUrl));
  });

  testWidgets('a managed invite runs out and is renewed like any code',
      (tester) async {
    final server = FakeInviteServer()..state = 'expired';
    final run = await _open(
      tester,
      profileId: 'ward-1',
      kind: 'managed',
      server: server,
    );
    await _create(tester);

    // The server says the code is gone before the countdown does.
    await tester.pump(InviteTiming.poll);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('invite-expired')), findsOneWidget);

    run.server.state = 'open';
    await tester.ensureVisible(find.byKey(const Key('invite-refresh')));
    await tester.tap(find.byKey(const Key('invite-refresh')));
    await tester.pumpAndSettle();
    expect(run.server.created, hasLength(2));
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
  });

  testWidgets('an accepted managed invite names the co-guardian',
      (tester) async {
    final run = await _open(tester, profileId: 'ward-1', kind: 'managed');
    await tester.tap(find.byKey(const ValueKey('invite-role-guardian')));
    await tester.pump();
    await _create(tester);

    run.server
      ..state = 'consumed'
      ..outgoing = [
        outgoingGrantJson(
          id: 'out-ward',
          profileId: 'ward-1',
          role: 'guardian',
          grantee: 'Alex Relative',
          profileKind: 'managed',
          profileName: 'Grace',
        ),
      ];
    await tester.pump(InviteTiming.poll);
    await tester.pumpAndSettle();

    expect(
      find.text('Alex Relative is now one of your relatives'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('invite-qr')), findsNothing);
  });

  testWidgets('leaving the code unshared revokes it', (tester) async {
    final run = await _open(tester, profileId: 'ward-1', kind: 'managed');
    await _create(tester);

    await tester.tap(find.byKey(const Key('invite-done')));
    await tester.pumpAndSettle();

    expect(run.server.revoked, [run.server.created.single['id']]);
  });

  testWidgets('a replayed create deletes the orphan invite and starts anew',
      (tester) async {
    // The first POST is answered as a replay of an earlier one.
    final server = FakeInviteServer()..replays = 1;
    final run = await _open(
      tester,
      profileId: 'ward-1',
      kind: 'managed',
      server: server,
    );
    await _create(tester);

    final firstId = run.server.created.first['id'];
    final secondId = run.server.created.last['id'];
    expect(run.server.created, hasLength(2));
    expect(secondId, isNot(firstId));
    // The first invite's token was lost with its response: it must not keep
    // one of the few open slots.
    expect(run.server.revoked.first, firstId);
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
  });

  testWidgets('only the owner of a live profile can invite', (tester) async {
    await _open(
      tester,
      profileId: 'ward-1',
      kind: 'managed',
      role: 'guardian',
    );
    expect(find.byKey(const Key('invite-not-allowed')), findsOneWidget);
    expect(find.byKey(const Key('invite-create')), findsNothing);
  });

  testWidgets('an archive cannot be shared', (tester) async {
    await _open(
      tester,
      profileId: 'ward-1',
      kind: 'managed',
      archived: true,
    );
    expect(find.byKey(const Key('invite-not-allowed')), findsOneWidget);
  });
}
