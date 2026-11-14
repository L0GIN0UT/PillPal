import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/family/invite_timing.dart';

import 'add_relative_support.dart';
import 'family_fixtures.dart';
import 'invite_server.dart';

// «Добавить близкого» (docs/adr/0020): the owner picks the role and confirms
// that role's disclosure, then shows a 15-minute QR code; the screen polls
// the code and says who accepted it with the role granted; a code nobody
// received is revoked when the owner leaves. Polling and races are in
// invite_code_polling_test.dart.

void main() {
  testWidgets('the role and its disclosure come first, then a viewer code',
      (tester) async {
    final run = await openAddRelative(tester);

    // Nothing is created before the owner confirms what becomes visible.
    expect(find.byKey(const Key('invite-disclosure')), findsOneWidget);
    expect(find.byKey(const Key('add-relative-editor')), findsOneWidget);
    expect(find.textContaining('Cannot change anything'), findsOneWidget);
    expect(find.byKey(const Key('invite-qr')), findsNothing);
    expect(run.server.created, isEmpty);
    // No name fields on this screen.
    expect(find.byType(TextField), findsNothing);

    await showCode(tester);

    final body = run.server.created.single;
    expect(body['role'], 'viewer');
    expect(body['disclosure_version'], 1);
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
    // Counted from the server's created_at / expires_at, not the phone's
    // clock (the test clock is an hour after created_at).
    expect(countdownText(tester), contains('15 min'));
    // The link is in the QR code and the share sheet only.
    expect(find.textContaining('links-ru.pillpal.invalid'), findsNothing);
    // While the code is shown the screen is about it alone.
    expect(find.byKey(const Key('add-relative-scan')), findsNothing);
    expect(find.byKey(const Key('add-relative-managed')), findsNothing);
    expect(find.byKey(const Key('add-relative-done')), findsOneWidget);
  });

  testWidgets('the helper box shows the helper disclosure before the code',
      (tester) async {
    final run = await openAddRelative(tester);

    await tapKey(tester, 'add-relative-editor');

    // The disclosure now explains the helper role; nothing is created yet.
    expect(find.textContaining('Cannot change anything'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('invite-disclosure')),
        matching: find.textContaining('can change them'),
      ),
      findsOneWidget,
    );
    expect(run.server.created, isEmpty);

    await showCode(tester);
    expect(run.server.created.single['role'], 'editor');
  });

  testWidgets(
      'changing the role after the code revokes it, even if shared, '
      'and asks again', (tester) async {
    final run = await openAddRelative(tester);
    await showCode(tester);
    final first = run.server.created.single['id'];
    await tapKey(tester, 'invite-share', settle: false);
    expect(run.shared, hasLength(1));

    await tapKey(tester, 'add-relative-editor');

    expect(run.server.revoked, [first]);
    expect(find.byKey(const Key('invite-qr')), findsNothing);
    expect(find.byKey(const Key('add-relative-show-code')), findsOneWidget);
    expect(run.server.created, hasLength(1));

    await showCode(tester);
    expect(run.server.created.last['role'], 'editor');
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
  });

  testWidgets('the code counts down, runs out and is renewed', (tester) async {
    final run = await openAddRelative(tester);
    await showCode(tester);

    run.harness.now = run.harness.now.add(const Duration(minutes: 10));
    await tester.pump(InviteTiming.tick);
    expect(countdownText(tester), contains('5 min'));

    // Seconds only in the last minute.
    run.harness.now =
        run.harness.now.add(const Duration(minutes: 4, seconds: 30));
    await tester.pump(InviteTiming.tick);
    expect(countdownText(tester), contains('30 s'));

    run.harness.now = run.harness.now.add(const Duration(seconds: 30));
    await tester.pump(InviteTiming.tick);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invite-qr')), findsNothing);
    expect(find.byKey(const Key('invite-expired')), findsOneWidget);
    final polls = run.server.polled.length;
    await tester.pump(InviteTiming.poll * 3);
    expect(run.server.polled, hasLength(polls));

    await tapKey(tester, 'invite-refresh');

    expect(run.server.created, hasLength(2));
    // The old code ran out by itself: nothing to revoke.
    expect(run.server.revoked, isEmpty);
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
    expect(countdownText(tester), contains('15 min'));
  });

  testWidgets(
      'share sends the canonical link with the minutes left; a '
      'shared code outlives the screen', (tester) async {
    // The server's spelling of the link is not what the app passes on.
    final server = FakeInviteServer()
      ..url = 'https://LINKS-RU.pillpal.invalid:443/i/#$inviteToken';
    final run = await openAddRelative(tester, server: server);
    await showCode(tester);

    run.harness.now =
        run.harness.now.add(const Duration(minutes: 10, seconds: 30));
    await tapKey(tester, 'invite-share', settle: false);
    expect(run.shared.single, contains(inviteUrl));
    expect(run.shared.single, isNot(contains(':443')));
    // 4 min 30 s left: rounded up.
    expect(run.shared.single, contains('5 min'));

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(run.server.revoked, isEmpty);
  });

  testWidgets(
      'an accepted code names the relative and the role, and can be '
      'revoked', (tester) async {
    final run = await openAddRelative(tester);
    await showCode(tester);

    run.server
      ..state = 'consumed'
      ..outgoing = [outgoingGrantJson(id: 'out-new', grantee: 'Мария')];
    await tester.pump(InviteTiming.poll);
    await tester.pumpAndSettle();

    expect(run.server.log, contains('GET /v1/grants'));
    expect(find.text('Мария is now one of your relatives'), findsOneWidget);
    expect(find.text('Role: observer'), findsOneWidget);
    final polls = run.server.polled.length;
    await tester.pump(InviteTiming.poll * 2);
    expect(run.server.polled, hasLength(polls));

    await tapKey(tester, 'relative-added-revoke');
    await tester.tap(find.byKey(const Key('confirm-yes')));
    await tester.pumpAndSettle();

    expect(run.server.log, contains('DELETE /v1/grants/out-new'));
    expect(find.byKey(const Key('relative-added')), findsNothing);
    // The used code itself is never revoked.
    expect(run.server.revoked, isEmpty);
  });

  testWidgets('two new links at once: success without a name or revoke',
      (tester) async {
    final run = await openAddRelative(tester);
    await showCode(tester);

    run.server
      ..state = 'consumed'
      ..outgoing = [
        outgoingGrantJson(id: 'out-a', grantee: 'Мария'),
        outgoingGrantJson(id: 'out-b', grantee: 'Пётр'),
      ];
    await tester.pump(InviteTiming.poll);
    await tester.pumpAndSettle();

    expect(find.text('Your relative has been added'), findsOneWidget);
    expect(find.textContaining('Мария'), findsNothing);
    expect(find.byKey(const Key('relative-added-revoke')), findsNothing);
  });

  testWidgets('leaving revokes a code nobody received', (tester) async {
    final run = await openAddRelative(tester);
    await showCode(tester);

    await tapKey(tester, 'add-relative-done');

    expect(run.server.revoked, [run.server.created.single['id']]);
    final polls = run.server.polled.length;
    await tester.pump(InviteTiming.poll * 3);
    expect(run.server.polled, hasLength(polls));
  });

  testWidgets('a link of a host this app does not serve is never shown',
      (tester) async {
    final server = FakeInviteServer()..url = foreignInviteUrl;
    final run = await openAddRelative(tester, server: server);
    await showCode(tester);

    expect(find.byKey(const Key('invite-qr')), findsNothing);
    expect(find.byKey(const Key('invite-share')), findsNothing);
    expect(find.byKey(const Key('invite-error')), findsOneWidget);
    expect(find.textContaining('evil.example'), findsNothing);
    expect(run.server.revoked, [run.server.created.single['id']]);
  });

  testWidgets('a server refusal is explained and renewed like an expiry',
      (tester) async {
    final server = FakeInviteServer()
      ..createAnswer = errorResponse(409, 'relatives_limit_reached');
    final run = await openAddRelative(tester, server: server);
    await showCode(tester);

    expect(find.textContaining('limit of relatives'), findsOneWidget);
    expect(find.byKey(const Key('invite-qr')), findsNothing);
    expect(
      tester.widget(find.byKey(const Key('invite-retry'))),
      isA<FilledButton>(),
    );

    run.server.createAnswer = null;
    await tapKey(tester, 'invite-retry');
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
  });

  testWidgets('«No smartphone? I will manage it» opens a managed profile',
      (tester) async {
    await openAddRelative(tester);
    expect(find.text("No smartphone? I'll manage it"), findsOneWidget);

    await tapKey(tester, 'add-relative-managed');

    expect(find.byKey(const Key('ward-name')), findsOneWidget);
  });
}
