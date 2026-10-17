import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/links/link_providers.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// Synthetic token (a bearer secret in real life).
const String _token = 'abcdefghijklmnopqrstuvwxyz012345';
const String _link = 'https://links-ru.pillpal.invalid/i#$_token';

Map<String, Object?> _preview({
  String role = 'viewer',
  String kind = 'self',
  String? inviter = 'Grace Owner',
}) =>
    {
      'inviter_display_name': inviter,
      'profile_display_name': 'Grace',
      'profile_kind': kind,
      'role': role,
      'expires_at': '2026-10-23T08:00:00Z',
    };

class _Requests {
  final List<http.Request> all = [];

  Iterable<String> get paths => all.map((r) => '${r.method} ${r.url.path}');

  bool get acceptedAnything =>
      all.any((r) => r.url.path == '/v1/invites/accept');
}

Future<({_Requests requests, ProviderContainer container})> _open(
  WidgetTester tester, {
  Map<String, Object?>? preview,
  http.Response? previewError,
  http.Response? acceptAnswer,
  String? heldLink,
}) async {
  final requests = _Requests();
  final harness = TestHarness(
    handler: (request) async {
      requests.all.add(request);
      switch (request.url.path) {
        case '/v1/invites/preview':
          return previewError ?? jsonResponse(preview ?? _preview());
        case '/v1/invites/accept':
          return acceptAnswer ??
              jsonResponse(
                incomingGrantJson(id: 'in-1', profileId: 'foreign-profile-1'),
                201,
              );
        case '/v1/grants':
          return jsonResponse(
            grantsJson(
              incoming: [
                incomingGrantJson(id: 'in-1', profileId: 'foreign-profile-1'),
              ],
            ),
          );
      }
      return http.Response('', 503);
    },
  );
  final container = createContainer(harness);
  await harness.seedSelfProfile();
  await pumpApp(tester, harness: harness, container: container);
  if (heldLink != null) {
    container.read(inviteIntakeProvider.notifier).offer(heldLink);
  }
  openRoute(container, AppRoutes.acceptInvite);
  await tester.pumpAndSettle();
  return (requests: requests, container: container);
}

Future<void> _paste(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('accept-link-field')), text);
  await tester.tap(find.byKey(const Key('accept-check')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a pasted link is previewed first and accepted only on confirm',
      (tester) async {
    final run = await _open(tester);

    await _paste(tester, 'Join me: $_link');

    expect(find.byKey(const Key('invite-preview-title')), findsOneWidget);
    expect(find.text('Grace Owner invites you'), findsOneWidget);
    expect(find.textContaining('Viewer.'), findsOneWidget);
    expect(find.byKey(const Key('guardian-warning')), findsNothing);
    // Preview changes nothing: no accept call before the explicit tap.
    expect(run.requests.paths, ['POST /v1/invites/preview']);
    expect(run.requests.acceptedAnything, isFalse);
    // The token travels in the body only, never in a URL.
    final preview = run.requests.all.single;
    expect(jsonDecode(preview.body), {'token': _token});
    expect(preview.url.toString(), isNot(contains(_token)));

    await tester.tap(find.byKey(const Key('accept-confirm')));
    await tester.pumpAndSettle();

    expect(run.requests.acceptedAnything, isTrue);
    final accept =
        run.requests.all.firstWhere((r) => r.url.path == '/v1/invites/accept');
    expect(jsonDecode(accept.body), {'token': _token});
    expect(accept.url.toString(), isNot(contains(_token)));
    expect(find.byKey(const Key('invite-accepted')), findsOneWidget);
    expect(find.text('You now see Grace'), findsOneWidget);
  });

  testWidgets('a link that opened the app waits for the confirmation too',
      (tester) async {
    final run = await _open(tester, heldLink: _link);

    expect(find.byKey(const Key('invite-preview-title')), findsOneWidget);
    expect(run.requests.acceptedAnything, isFalse);
    expect(find.byKey(const Key('accept-confirm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('accept-decline')));
    await tester.pumpAndSettle();
    expect(run.requests.acceptedAnything, isFalse);
  });

  testWidgets('a guardian invite carries its own warning', (tester) async {
    final run = await _open(
      tester,
      preview: _preview(role: 'guardian', kind: 'managed'),
    );

    await _paste(tester, _link);

    expect(find.byKey(const Key('guardian-warning')), findsOneWidget);
    expect(find.textContaining('"Only me" medications'), findsWidgets);
    expect(find.textContaining('You can leave at any time'), findsOneWidget);
    expect(run.requests.acceptedAnything, isFalse);
  });

  testWidgets('a link of the other region is refused without any request',
      (tester) async {
    final run = await _open(tester);

    await _paste(tester, 'https://links-eu.pillpal.invalid/i#$_token');

    expect(find.byKey(const Key('accept-problem')), findsOneWidget);
    expect(find.textContaining('another data region'), findsOneWidget);
    expect(run.requests.all, isEmpty);
  });

  testWidgets('unknown hosts and non-links are refused without any request',
      (tester) async {
    final run = await _open(tester);

    await _paste(tester, 'https://evil.example/i#$_token');
    expect(find.textContaining('not from PillPal'), findsOneWidget);

    await _paste(tester, 'pillpal://i#$_token');
    expect(find.textContaining('not a PillPal invite link'), findsOneWidget);

    await _paste(tester, 'hello');
    expect(find.textContaining('not a PillPal invite link'), findsOneWidget);
    expect(run.requests.all, isEmpty);
  });

  testWidgets('an expired invite is explained and the form comes back',
      (tester) async {
    await _open(
      tester,
      previewError: errorResponse(410, 'invite_expired'),
    );

    await _paste(tester, _link);

    expect(find.byKey(const Key('accept-error')), findsOneWidget);
    expect(find.textContaining('has expired'), findsOneWidget);
    expect(find.byKey(const Key('accept-link-field')), findsOneWidget);
  });

  testWidgets('an invite to the own profile is refused by the server',
      (tester) async {
    await _open(
      tester,
      acceptAnswer: errorResponse(409, 'invite_own_profile'),
    );
    await _paste(tester, _link);

    await tester.tap(find.byKey(const Key('accept-confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('your own profile'), findsOneWidget);
    expect(find.byKey(const Key('invite-accepted')), findsNothing);
  });

  testWidgets('paste button reads the clipboard', (tester) async {
    await _open(tester);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, Object?>{'text': _link}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.tap(find.byKey(const Key('accept-paste')));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const Key('accept-link-field')),
    );
    expect(field.controller!.text, _link);
  });
}
