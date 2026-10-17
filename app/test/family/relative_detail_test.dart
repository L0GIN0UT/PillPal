import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

Future<List<RelativeLinkRow>> _stored(TestHarness harness) =>
    harness.db.select(harness.db.relativeLinks).get();

class _Calls {
  final List<String> log = [];
  final List<Map<String, Object?>> bodies = [];
}

Future<({_Calls calls, TestHarness harness})> _open(
  WidgetTester tester, {
  required String linkId,
  Future<http.Response> Function(http.Request request)? answer,
  Future<void> Function(TestHarness harness)? seed,
}) async {
  final calls = _Calls();
  final harness = TestHarness(
    handler: (request) async {
      calls.log.add('${request.method} ${request.url.path}');
      if (request.body.isNotEmpty) {
        calls.bodies.add(jsonDecode(request.body) as Map<String, Object?>);
      }
      if (answer != null) {
        return answer(request);
      }
      return request.method == 'GET'
          ? http.Response('', 503)
          : http.Response('', 204);
    },
  );
  final container = createContainer(harness);
  await harness.seedSelfProfile();
  await seed?.call(harness);
  await pumpApp(tester, harness: harness, container: container);
  openRoute(container, AppRoutes.link(linkId));
  await tester.pumpAndSettle();
  calls.log.clear();
  calls.bodies.clear();
  return (calls: calls, harness: harness);
}

void main() {
  group('owner of an outgoing link', () {
    testWidgets('changes viewer to editor with the disclosure version',
        (tester) async {
      final run = await _open(
        tester,
        linkId: 'out-1',
        seed: (harness) => seedLink(harness, id: 'out-1'),
      );

      expect(find.text('Alex Relative'), findsOneWidget);
      expect(find.byKey(const Key('invite-disclosure')), findsOneWidget);
      // Nothing to save until the role changes.
      var save = tester.widget<FilledButton>(
        find.byKey(const Key('detail-save-role')),
      );
      expect(save.onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('detail-role-editor')));
      await tester.pump();
      save = tester.widget<FilledButton>(
        find.byKey(const Key('detail-save-role')),
      );
      expect(save.onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('detail-save-role')));
      await tester.pumpAndSettle();

      expect(run.calls.log, contains('PATCH /v1/grants/out-1'));
      // Only the role and the disclosure version: never mixed with
      // `notify_missed`, which only the grantee may change.
      expect(run.calls.bodies.single, {
        'role': 'editor',
        'disclosure_version': 1,
      });
      final stored = await _stored(run.harness);
      expect(stored.single.role, 'editor');
    });

    testWidgets('a guardian role is fixed: it can only be revoked',
        (tester) async {
      await _open(
        tester,
        linkId: 'out-1',
        seed: (harness) => seedLink(
          harness,
          id: 'out-1',
          role: 'guardian',
          profileKind: 'managed',
          profileName: 'Pat Ward',
        ),
      );

      expect(find.byKey(const Key('detail-save-role')), findsNothing);
      expect(find.byKey(const ValueKey('detail-role-viewer')), findsNothing);
      expect(find.byKey(const Key('detail-revoke')), findsOneWidget);
    });

    testWidgets('revoke asks first, then deletes the grant', (tester) async {
      final run = await _open(
        tester,
        linkId: 'out-1',
        seed: (harness) => seedLink(harness, id: 'out-1'),
      );

      await tester.tap(find.byKey(const Key('detail-revoke')));
      await tester.pumpAndSettle();
      expect(find.text('Revoke access for Alex Relative?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-no')));
      await tester.pumpAndSettle();
      expect(run.calls.log, isEmpty);

      await tester.tap(find.byKey(const Key('detail-revoke')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-yes')));
      await tester.pumpAndSettle();

      expect(run.calls.log, contains('DELETE /v1/grants/out-1'));
      final stored = await _stored(run.harness);
      expect(stored, isEmpty);
    });

    testWidgets('an inactive link says so and can still be revoked',
        (tester) async {
      await _open(
        tester,
        linkId: 'out-1',
        seed: (harness) => seedLink(harness, id: 'out-1', active: false),
      );

      expect(find.byKey(const Key('link-inactive')), findsOneWidget);
      // No role change while the access is paused.
      expect(find.byKey(const Key('detail-save-role')), findsNothing);
      expect(find.byKey(const Key('detail-revoke')), findsOneWidget);
    });

    testWidgets('a revoke that is already done on the server counts as done',
        (tester) async {
      final run = await _open(
        tester,
        linkId: 'out-1',
        answer: (request) async => errorResponse(404, 'not_found'),
        seed: (harness) => seedLink(harness, id: 'out-1'),
      );

      await tester.tap(find.byKey(const Key('detail-revoke')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-yes')));
      await tester.pumpAndSettle();

      final stored = await _stored(run.harness);
      expect(stored, isEmpty);
    });
  });

  group('grantee of an incoming link', () {
    Future<void> seedIncoming(TestHarness harness) async {
      await seedLink(
        harness,
        id: 'in-1',
        direction: LinkDirection.incoming,
        profileId: 'foreign-profile-1',
        counterpart: 'Grace Owner',
        profileName: 'Grace',
        role: 'editor',
      );
      await seedProfile(harness, role: 'editor');
    }

    testWidgets('chooses whether to be alerted about missed doses',
        (tester) async {
      final run = await _open(tester, linkId: 'in-1', seed: seedIncoming);

      expect(find.text('Grace'), findsWidgets);
      expect(find.text('Owner: Grace Owner'), findsOneWidget);
      var toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('notify-missed')),
      );
      expect(toggle.value, isTrue);

      await tester.tap(find.byKey(const Key('notify-missed')));
      await tester.pumpAndSettle();

      expect(run.calls.log, ['PATCH /v1/grants/in-1']);
      expect(run.calls.bodies.single, {'notify_missed': false});
      toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('notify-missed')),
      );
      expect(toggle.value, isFalse);
    });

    testWidgets('leaving asks first and deletes the grant', (tester) async {
      final run = await _open(tester, linkId: 'in-1', seed: seedIncoming);
      final syncsBefore = run.harness.syncCalls;

      await tester.tap(find.byKey(const Key('detail-leave')));
      await tester.pumpAndSettle();
      expect(find.text('Stop seeing Grace?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-yes')));
      await tester.pumpAndSettle();

      expect(run.calls.log, contains('DELETE /v1/grants/in-1'));
      final stored = await _stored(run.harness);
      expect(stored, isEmpty);
      // Leaving starts a sync: the next pull evicts the profile.
      expect(run.harness.syncCalls, greaterThan(syncsBefore));
    });
  });

  testWidgets('a link that is gone says so', (tester) async {
    await _open(tester, linkId: 'missing');
    expect(find.byKey(const Key('relative-gone')), findsOneWidget);
  });
}
