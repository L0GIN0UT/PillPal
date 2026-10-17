import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/today/dose_tile.dart';
import 'package:pillpal/src/routing/router.dart';

import '../support/app_driver.dart';
import '../support/auth_steps.dart';
import '../support/host.dart';

/// Phase `relatives` (after `sign_out`: the welcome screen): the app is the
/// relative of an owner the host plays through the API (ADR 0005-0010).
///
/// 1. register, then the host creates the owner with a `shared`, an
///    `anonymous` and a `hidden` medication and a viewer invite, and delivers
///    the invite link like a tap on it (view intent, explicit package);
/// 2. the app shows the preview and the journey confirms it;
/// 3. the Family tab lists the owner; their day view shows the shared name, a
///    generic entry for the anonymous medication and nothing of the hidden
///    one, and no mark button;
/// 4. the host revokes the grant; the next sync evicts the scope, the link
///    and the data.
Future<void> relativesPhase(WidgetTester tester, HostControl host) async {
  final container = await launchApp(tester);
  await registerThroughUi(tester, host);
  final db = container.read(databaseProvider);
  final router = container.read(routerProvider);

  final names = await host.relativesSetup();
  await host.relativesOpenLink();
  await waitFor(
    tester,
    find.byKey(const Key('invite-preview-title')),
    reason: 'the invite preview',
  );
  await tapVisible(tester, find.byKey(const Key('accept-confirm')));
  await waitFor(
    tester,
    find.byKey(const Key('invite-accepted')),
    reason: 'the confirmation of the accepted invite',
  );
  await tapVisible(tester, find.byKey(const Key('accepted-done')));

  final link = await _incomingLink(tester, db);
  router.go(AppRoutes.family);
  final tile = find.byKey(ValueKey('link-${link.id}'));
  await waitFor(tester, tile, reason: 'the Family tab to list the owner');

  await _scopeDataArrived(tester, db, link.profileId);
  await tapVisible(tester, tile);
  await _checkDayView(tester, db, link.profileId, names);

  router.go(AppRoutes.family);
  await waitFor(tester, tile, reason: 'the Family tab');
  await quiesce(tester, container); // no sync of ours may overlap the next
  await host.relativesRevoke();
  final report = await container.read(syncEngineProvider).sync();
  expect(report.ok, isTrue, reason: 'sync after the revocation');
  await _evicted(tester, db, link.profileId);
  await pumpUntil(
    tester,
    () => tile.evaluate().isEmpty,
    reason: 'the Family tab to drop the owner',
  );
  await quiesce(tester, container);
}

Future<RelativeLinkRow> _incomingLink(
  WidgetTester tester,
  AppDatabase db,
) async {
  late RelativeLinkRow found;
  await pumpUntil(
    tester,
    () async {
      final rows = await (db.select(db.relativeLinks)
            ..where((row) => row.direction.equals('incoming')))
          .get();
      if (rows.isEmpty) {
        return false;
      }
      found = rows.single;
      return true;
    },
    reason: 'the accepted link to be stored',
  );
  expect(found.role, 'viewer');
  return found;
}

/// The scope arrived by sync: two medications (the hidden one never does).
Future<void> _scopeDataArrived(
  WidgetTester tester,
  AppDatabase db,
  String profileId,
) async {
  await pumpUntil(
    tester,
    () async => (await _medications(db, profileId)).length >= 2,
    reason: 'the shared scope to arrive by sync',
  );
  expect(await _medications(db, profileId), hasLength(2));
}

Future<List<MedicationRow>> _medications(AppDatabase db, String profileId) {
  return (db.select(db.medications)
        ..where((row) => row.profileId.equals(profileId)))
      .get();
}

Future<void> _checkDayView(
  WidgetTester tester,
  AppDatabase db,
  String profileId,
  Map<String, String> names,
) async {
  final medications = await _medications(db, profileId);
  final shared = medications.singleWhere((row) => row.name == names['shared']);
  final anonymous = medications.singleWhere((row) => row.redacted);
  expect(anonymous.name, isNull, reason: 'an anonymous name never arrives');

  final schedules = await db.select(db.schedules).get();
  String scheduleOf(MedicationRow row) =>
      schedules.singleWhere((s) => s.medicationId == row.id).id;
  Finder tileOf(String scheduleId) => find.byWidgetPredicate((widget) {
        final key = widget.key;
        return widget is DoseTile &&
            key is ValueKey<String> &&
            key.value.startsWith('$scheduleId/');
      });
  await waitFor(
    tester,
    tileOf(scheduleOf(shared)),
    reason: 'the day view to show the shared dose',
  );
  expect(tileOf(scheduleOf(anonymous)), findsOneWidget);
  expect(find.byType(DoseTile), findsNWidgets(2), reason: 'no hidden dose');
  expect(find.text(names['shared']!), findsWidgets);
  expect(find.text(names['anonymous']!), findsNothing);
  expect(find.text(names['hidden']!), findsNothing);
  expect(
    find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> && key.value.startsWith('dose-take-');
    }),
    findsNothing,
    reason: 'a viewer cannot mark doses',
  );
}

Future<void> _evicted(
  WidgetTester tester,
  AppDatabase db,
  String profileId,
) async {
  await pumpUntil(
    tester,
    () async {
      final scopes = await (db.select(db.accessScopes)
            ..where((row) => row.profileId.equals(profileId)))
          .get();
      return scopes.isEmpty;
    },
    reason: 'the revoked scope to be evicted',
  );
  expect(await _medications(db, profileId), isEmpty);
  expect(await db.select(db.schedules).get(), isEmpty);
}
