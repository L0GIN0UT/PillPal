import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

Future<TestHarness> _open(
  WidgetTester tester,
  String Function(String profileId) location, {
  String role = 'owner',
  bool archived = false,
}) async {
  final harness = TestHarness();
  final container = createContainer(harness);
  await harness.seedSelfProfile();
  final profile = await seedProfile(
    harness,
    id: 'ward-1',
    kind: 'managed',
    role: role,
    name: 'Pat Ward',
    zone: 'Europe/Berlin',
    archived: archived,
  );
  await pumpApp(tester, harness: harness, container: container);
  openRoute(container, location(profile));
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

void main() {
  group('create', () {
    Future<TestHarness> openNew(WidgetTester tester) async {
      final harness = TestHarness();
      final container = createContainer(harness);
      await harness.seedSelfProfile();
      await pumpApp(tester, harness: harness, container: container);
      openRoute(container, AppRoutes.newManagedProfile);
      await tester.pumpAndSettle();
      return harness;
    }

    testWidgets('name, zone and alert defaults; saved and queued for sync',
        (tester) async {
      final harness = await openNew(tester);
      final syncsBefore = harness.syncCalls;

      // The zone starts as the device's.
      final zone = tester.widget<TextField>(find.byKey(const Key('ward-zone')));
      expect(zone.controller!.text, testZone);
      await _enter(tester, 'ward-name', 'Pat Ward');
      await _enter(tester, 'ward-minutes', '90');
      await tester.tap(find.byKey(const Key('ward-save')));
      await tester.pumpAndSettle();

      final rows = await harness.db.select(harness.db.profiles).get();
      final ward = rows.singleWhere((row) => row.kind == 'managed');
      expect(ward.displayName, 'Pat Ward');
      expect(ward.timezone, testZone);
      expect(ward.missedAlertMinutes, 90);
      expect(ward.missedAlertsEnabled, isTrue);
      expect(harness.syncCalls, greaterThan(syncsBefore));
      final outbox = await harness.db.select(harness.db.outbox).get();
      expect(outbox.map((e) => e.entityKind), contains('profile'));
    });

    testWidgets('a bad zone, name or minutes is shown and nothing is saved',
        (tester) async {
      final harness = await openNew(tester);

      await _enter(tester, 'ward-name', '   ');
      await tester.tap(find.byKey(const Key('ward-save')));
      await tester.pumpAndSettle();
      expect(find.text('Check this field'), findsOneWidget);

      await _enter(tester, 'ward-name', 'Pat Ward');
      await _enter(tester, 'ward-zone', 'Mars/Olympus');
      await tester.tap(find.byKey(const Key('ward-save')));
      await tester.pumpAndSettle();
      expect(find.text('Check this field'), findsOneWidget);

      await _enter(tester, 'ward-zone', 'Europe/Berlin');
      await _enter(tester, 'ward-minutes', '4');
      await tester.tap(find.byKey(const Key('ward-save')));
      await tester.pumpAndSettle();
      expect(find.text('Check this field'), findsOneWidget);

      final rows = await harness.db.select(harness.db.profiles).get();
      expect(rows.where((row) => row.kind == 'managed'), isEmpty);
    });

    testWidgets('alerts off hides the minutes and is stored', (tester) async {
      final harness = await openNew(tester);

      await _enter(tester, 'ward-name', 'Pat Ward');
      await tester.tap(find.byKey(const Key('ward-alerts')));
      await tester.pump();
      expect(find.byKey(const Key('ward-minutes')), findsNothing);
      await tester.tap(find.byKey(const Key('ward-save')));
      await tester.pumpAndSettle();

      final rows = await harness.db.select(harness.db.profiles).get();
      expect(
        rows.singleWhere((row) => row.kind == 'managed').missedAlertsEnabled,
        isFalse,
      );
    });
  });

  group('edit', () {
    testWidgets('the owner renames, invites a co-guardian and deletes',
        (tester) async {
      final harness = await _open(tester, AppRoutes.managedProfile);

      expect(find.text('Pat Ward'), findsOneWidget);
      expect(find.byKey(const Key('ward-invite')), findsOneWidget);
      expect(find.byKey(const Key('ward-delete')), findsOneWidget);
      await _enter(tester, 'ward-name', 'Pat B. Ward');
      await tester.tap(find.byKey(const Key('ward-save')));
      await tester.pumpAndSettle();

      final ward = await harness.db.select(harness.db.profiles).get();
      expect(
        ward.singleWhere((row) => row.id == 'ward-1').displayName,
        'Pat B. Ward',
      );
    });

    testWidgets('a co-guardian edits alerts but cannot invite or delete',
        (tester) async {
      await _open(tester, AppRoutes.managedProfile, role: 'guardian');

      expect(find.byKey(const Key('ward-save')), findsOneWidget);
      expect(find.byKey(const Key('ward-invite')), findsNothing);
      expect(find.byKey(const Key('ward-delete')), findsNothing);
    });

    testWidgets('"remind on this device" is a per-device switch',
        (tester) async {
      final harness = await _open(
        tester,
        AppRoutes.managedProfile,
        role: 'guardian',
      );

      // A co-guardian does not remind by default (ADR 0005 §2).
      var remind = tester.widget<SwitchListTile>(
        find.byKey(const Key('ward-remind')),
      );
      expect(remind.value, isFalse);
      await tester.tap(find.byKey(const Key('ward-remind')));
      await tester.pumpAndSettle();

      remind = tester.widget<SwitchListTile>(
        find.byKey(const Key('ward-remind')),
      );
      expect(remind.value, isTrue);
      final stored =
          await harness.db.select(harness.db.profileDeviceSettings).get();
      expect(stored.single.profileId, 'ward-1');
      expect(stored.single.remindOnDevice, isTrue);
    });

    testWidgets('delete asks first, then removes the profile', (tester) async {
      final harness = await _open(tester, AppRoutes.managedProfile);

      await tester.tap(find.byKey(const Key('ward-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete Pat Ward?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-no')));
      await tester.pumpAndSettle();
      var rows = await harness.db.select(harness.db.profiles).get();
      expect(rows.singleWhere((r) => r.id == 'ward-1').deletedAt, isNull);

      await tester.tap(find.byKey(const Key('ward-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-yes')));
      await tester.pumpAndSettle();
      rows = await harness.db.select(harness.db.profiles).get();
      expect(rows.singleWhere((r) => r.id == 'ward-1').deletedAt, isNotNull);
    });

    testWidgets('an archive or a viewer has nothing to edit', (tester) async {
      await _open(
        tester,
        AppRoutes.managedProfile,
        role: 'guardian',
        archived: true,
      );
      expect(find.text('This profile is read-only.'), findsOneWidget);
      expect(find.byKey(const Key('ward-save')), findsNothing);
    });
  });
}
