import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/links/link_providers.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// Synthetic invite link: the token is a bearer secret, shown once.
const String _url =
    'https://links-ru.pillpal.invalid/i#abcdefghijklmnopqrstuvwxyz012345';

Map<String, Object?> _created(String id, {String role = 'viewer'}) => {
      'id': id,
      'role': role,
      'expires_at': '2026-10-23T08:00:00Z',
      'url': _url,
    };

class _Calls {
  final List<String> log = [];
  final List<Map<String, Object?>> bodies = [];
}

Future<({TestHarness harness, List<String> shared, _Calls calls})> _open(
  WidgetTester tester, {
  required String profileId,
  Future<http.Response> Function(http.Request request, _Calls calls)? answer,
  String role = 'owner',
  String kind = 'self',
  bool archived = false,
}) async {
  final calls = _Calls();
  final harness = TestHarness(
    handler: (request) async {
      calls.log.add('${request.method} ${request.url.path}');
      if (request.body.isNotEmpty) {
        calls.bodies.add(jsonDecode(request.body) as Map<String, Object?>);
      }
      if (answer != null) {
        return answer(request, calls);
      }
      return jsonResponse(_created('created-1'), 201);
    },
  );
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
  return (harness: harness, shared: shared, calls: calls);
}

void main() {
  testWidgets('own profile: viewer or editor, disclosure, QR and share',
      (tester) async {
    final run = await _open(tester, profileId: selfProfileId);

    expect(find.byKey(const ValueKey('invite-role-viewer')), findsOneWidget);
    expect(find.byKey(const ValueKey('invite-role-editor')), findsOneWidget);
    // Guardians are for managed profiles only.
    expect(find.byKey(const ValueKey('invite-role-guardian')), findsNothing);
    final disclosure = find.byKey(const Key('invite-disclosure'));
    expect(disclosure, findsOneWidget);
    expect(find.textContaining('Your time zone'), findsOneWidget);
    expect(find.textContaining('"Only me": nothing at all'), findsOneWidget);
    expect(find.textContaining('"Without name"'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('invite-role-editor')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('invite-create')));
    await tester.pumpAndSettle();

    expect(run.calls.log, ['POST /v1/profiles/$selfProfileId/invites']);
    final body = run.calls.bodies.single;
    expect(body['role'], 'editor');
    expect(body['disclosure_version'], 1);
    expect(body['id'], isA<String>());
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
    expect(find.textContaining('October 23'), findsOneWidget);
    // The link is shown in the QR code and the share sheet only.
    expect(find.textContaining('links-ru.pillpal.invalid'), findsNothing);

    await tester.tap(find.byKey(const Key('invite-share')));
    await tester.pump();
    expect(run.shared.single, contains(_url));
  });

  testWidgets('managed profile: guardian is offered with its own disclosure',
      (tester) async {
    final run = await _open(
      tester,
      profileId: 'ward-1',
      kind: 'managed',
    );

    expect(find.byKey(const ValueKey('invite-role-guardian')), findsOneWidget);
    // A managed profile has no phone of its own to disclose.
    expect(find.textContaining('Your time zone'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('invite-role-guardian')));
    await tester.pump();
    expect(
        find.textContaining('also sees "Only me" medications'), findsOneWidget);

    await tester.tap(find.byKey(const Key('invite-create')));
    await tester.pumpAndSettle();
    expect(run.calls.bodies.single['role'], 'guardian');
    expect(run.calls.log.single, 'POST /v1/profiles/ward-1/invites');
  });

  testWidgets('a replayed create deletes the orphan invite and starts anew',
      (tester) async {
    var posts = 0;
    final run = await _open(
      tester,
      profileId: selfProfileId,
      answer: (request, calls) async {
        if (request.method == 'POST') {
          posts++;
          return posts == 1
              ? errorResponse(409, 'already_exists')
              : jsonResponse(_created('second'), 201);
        }
        return http.Response('', 204);
      },
    );

    await tester.tap(find.byKey(const Key('invite-create')));
    await tester.pumpAndSettle();

    expect(run.calls.log, [
      'POST /v1/profiles/$selfProfileId/invites',
      // The first invite's token was lost with its response: it must not
      // keep one of the few open slots.
      startsWith('DELETE /v1/profiles/$selfProfileId/invites/'),
      'POST /v1/profiles/$selfProfileId/invites',
    ]);
    final firstId = run.calls.bodies.first['id'];
    final secondId = run.calls.bodies.last['id'];
    expect(secondId, isNot(firstId));
    expect(run.calls.log[1], endsWith('/$firstId'));
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
  });

  testWidgets('a server refusal is explained', (tester) async {
    await _open(
      tester,
      profileId: selfProfileId,
      answer: (request, calls) async =>
          errorResponse(409, 'relatives_limit_reached'),
    );

    await tester.tap(find.byKey(const Key('invite-create')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invite-error')), findsOneWidget);
    expect(find.textContaining('limit of relatives'), findsOneWidget);
    expect(find.byKey(const Key('invite-qr')), findsNothing);
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
