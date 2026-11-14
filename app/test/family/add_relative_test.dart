import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/features/common/status_pill.dart';
import 'package:pillpal/src/features/family/invite_timing.dart';
import 'package:pillpal/src/links/link_providers.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'family_fixtures.dart';
import 'invite_server.dart';

// «Добавить близкого» (docs/adr/0020): the owner confirms the disclosure,
// then shows a 15-minute QR code; the box under it makes a helper's code; the
// screen polls the code and says who accepted it; a code nobody received is
// revoked when the owner leaves.

class _Run {
  _Run(this.harness, this.server, this.container, this.shared);

  final TestHarness harness;
  final FakeInviteServer server;
  final ProviderContainer container;
  final List<String> shared;
}

Future<_Run> _open(WidgetTester tester, {FakeInviteServer? server}) async {
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
  await pumpApp(tester, harness: harness, container: container);
  openRoute(container, AppRoutes.addRelative);
  await tester.pumpAndSettle();
  return _Run(harness, fake, container, shared);
}

Future<void> _showCode(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('add-relative-show-code')));
  await tester.tap(find.byKey(const Key('add-relative-show-code')));
  await tester.pumpAndSettle();
}

String _countdown(WidgetTester tester) =>
    tester.widget<StatusPill>(find.byKey(const Key('invite-countdown'))).label!;

void main() {
  testWidgets('the disclosure comes first, then a viewer code', (tester) async {
    final run = await _open(tester);

    // Nothing is created before the owner confirms what becomes visible.
    expect(find.byKey(const Key('invite-disclosure')), findsOneWidget);
    expect(find.byKey(const Key('invite-qr')), findsNothing);
    expect(run.server.created, isEmpty);
    // No name fields on this screen.
    expect(find.byType(TextField), findsNothing);

    await _showCode(tester);

    final body = run.server.created.single;
    expect(body['role'], 'viewer');
    expect(body['disclosure_version'], 1);
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
    // Counted from the server's created_at / expires_at, not the phone's
    // clock (the test clock is an hour after created_at).
    expect(_countdown(tester), contains('15:00'));
    // The link is in the QR code and the share sheet only.
    expect(find.textContaining('links-ru.pillpal.invalid'), findsNothing);
    expect(find.byKey(const Key('add-relative-editor')), findsOneWidget);
  });

  testWidgets('the helper box makes an editor code and revokes the old one',
      (tester) async {
    final run = await _open(tester);
    await _showCode(tester);
    final first = run.server.created.single['id'];

    await tester.ensureVisible(find.byKey(const Key('add-relative-editor')));
    await tester.tap(find.byKey(const Key('add-relative-editor')));
    await tester.pumpAndSettle();

    expect(run.server.created, hasLength(2));
    expect(run.server.created.last['role'], 'editor');
    expect(run.server.created.last['id'], isNot(first));
    expect(run.server.revoked, [first]);
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
  });

  testWidgets('the code counts down, runs out and is renewed', (tester) async {
    final run = await _open(tester);
    await _showCode(tester);

    run.harness.now = run.harness.now.add(const Duration(minutes: 10));
    await tester.pump(InviteTiming.tick);
    expect(_countdown(tester), contains('5:00'));

    run.harness.now = run.harness.now.add(const Duration(minutes: 5));
    await tester.pump(InviteTiming.tick);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invite-qr')), findsNothing);
    expect(find.byKey(const Key('invite-expired')), findsOneWidget);
    // An expired code is not polled any more.
    final polls = run.server.polled.length;
    await tester.pump(InviteTiming.poll * 3);
    expect(run.server.polled, hasLength(polls));

    await tester.ensureVisible(find.byKey(const Key('invite-refresh')));
    await tester.tap(find.byKey(const Key('invite-refresh')));
    await tester.pumpAndSettle();

    expect(run.server.created, hasLength(2));
    // The old code ran out by itself: nothing to revoke.
    expect(run.server.revoked, isEmpty);
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
    expect(_countdown(tester), contains('15:00'));
  });

  testWidgets('share hands over the link; a shared code outlives the screen',
      (tester) async {
    final run = await _open(tester);
    await _showCode(tester);

    await tester.ensureVisible(find.byKey(const Key('invite-share')));
    await tester.tap(find.byKey(const Key('invite-share')));
    await tester.pump();
    expect(run.shared.single, contains(inviteUrl));
    expect(run.shared.single, contains('15 min'));

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(run.server.revoked, isEmpty);
  });

  testWidgets('an accepted code says who joined and refreshes the list',
      (tester) async {
    final run = await _open(tester);
    await _showCode(tester);
    expect(run.server.polled, isEmpty);

    run.server
      ..state = 'consumed'
      ..outgoing = [outgoingGrantJson(id: 'out-new', grantee: 'Мария')];
    await tester.pump(InviteTiming.poll);
    await tester.pumpAndSettle();

    expect(run.server.polled, [run.server.created.single['id']]);
    expect(run.server.log, contains('GET /v1/grants'));
    expect(find.byKey(const Key('relative-added')), findsOneWidget);
    expect(find.text('Мария is now one of your relatives'), findsOneWidget);
    final links = await run.container.read(relativesRepositoryProvider).links();
    expect(links.single.direction, LinkDirection.outgoing);

    // Polling stopped; leaving revokes nothing (the code was used).
    final polls = run.server.polled.length;
    await tester.pump(InviteTiming.poll * 2);
    expect(run.server.polled, hasLength(polls));
    await tester.tap(find.byKey(const Key('relative-added-done')));
    await tester.pumpAndSettle();
    expect(run.server.revoked, isEmpty);
    expect(find.byKey(const Key('relative-added')), findsNothing);
  });

  testWidgets('leaving revokes a code nobody received and stops polling',
      (tester) async {
    final run = await _open(tester);
    await _showCode(tester);
    await tester.pump(InviteTiming.poll);
    expect(run.server.polled, hasLength(1));

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(run.server.revoked, [run.server.created.single['id']]);
    await tester.pump(InviteTiming.poll * 3);
    expect(run.server.polled, hasLength(1));
  });

  testWidgets('a link of a host this app does not serve is never shown',
      (tester) async {
    final server = FakeInviteServer()..url = foreignInviteUrl;
    final run = await _open(tester, server: server);
    await _showCode(tester);

    expect(find.byKey(const Key('invite-qr')), findsNothing);
    expect(find.byKey(const Key('invite-share')), findsNothing);
    expect(find.byKey(const Key('invite-error')), findsOneWidget);
    expect(find.textContaining('evil.example'), findsNothing);
    expect(run.server.revoked, [run.server.created.single['id']]);
  });

  testWidgets('a server refusal is explained and can be retried',
      (tester) async {
    final server = FakeInviteServer()
      ..createAnswer = errorResponse(409, 'relatives_limit_reached');
    final run = await _open(tester, server: server);
    await _showCode(tester);

    expect(find.textContaining('limit of relatives'), findsOneWidget);
    expect(find.byKey(const Key('invite-qr')), findsNothing);

    run.server.createAnswer = null;
    await tester.ensureVisible(find.byKey(const Key('invite-retry')));
    await tester.tap(find.byKey(const Key('invite-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
  });

  testWidgets('«No smartphone? I will manage it» opens a managed profile',
      (tester) async {
    await _open(tester);
    final link = find.byKey(const Key('add-relative-managed'));
    await tester.ensureVisible(link);
    expect(find.text("No smartphone? I'll manage it"), findsOneWidget);

    await tester.tap(link);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ward-name')), findsOneWidget);
  });
}
