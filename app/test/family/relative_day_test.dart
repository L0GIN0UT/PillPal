import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// A relative's day view reuses Today with the profile's id: D3 (editors and
// viewers never mark), D1 (archives are read-only), D4 (the profile's zone)
// and the privacy projection (`anonymous` shows no name).

Future<_Day> _open(
  WidgetTester tester, {
  String role = 'viewer',
  String kind = 'self',
  String privacy = 'shared',
  bool redacted = false,
  bool archived = false,
  DateTime? purgeAfter,
  DateTime? ownerLastSeenAt,
  String zone = 'Europe/Berlin',
}) async {
  final harness = TestHarness();
  final container = createContainer(harness);
  await harness.seedSelfProfile();
  final profile = await seedProfile(
    harness,
    role: role,
    kind: kind,
    archived: archived,
    purgeAfter: purgeAfter,
    ownerLastSeenAt: ownerLastSeenAt,
    zone: zone,
  );
  final ids = await seedForeignMedication(
    harness,
    container,
    profile,
    name: 'Secret Name',
    privacy: privacy,
    redacted: redacted,
  );
  await pumpApp(tester, harness: harness, container: container);
  openRoute(container, AppRoutes.profileToday(profile));
  await tester.pumpAndSettle();
  return _Day(profile, ids.schedule);
}

class _Day {
  _Day(this.profile, this.schedule);

  final String profile;
  final String schedule;

  String get morning => '$schedule/2026-10-16T08:00';
}

void main() {
  group('viewer', () {
    testWidgets('sees the status of shared medications and cannot mark',
        (tester) async {
      final day = await _open(tester);

      expect(find.byKey(const Key('today-title')), findsOneWidget);
      expect(find.text('Grace'), findsOneWidget);
      expect(find.text('Secret Name'), findsOneWidget);
      expect(
          find.byKey(ValueKey('dose-status-${day.morning}')), findsOneWidget);
      // No mark buttons of any kind, and nothing opens on tap (D3).
      expect(find.byKey(ValueKey('dose-take-${day.morning}')), findsNothing);
      expect(find.byKey(ValueKey('dose-missed-${day.morning}')), findsNothing);
      expect(find.byKey(const Key('today-add')), findsNothing);
      await tester.tap(find.byKey(ValueKey(day.morning)));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('an anonymous medication is a generic one, never named',
        (tester) async {
      await _open(tester, privacy: 'anonymous', redacted: true);

      expect(find.text('Medication'), findsWidgets);
      // The row even carries a name here: the screen must not use it.
      expect(find.textContaining('Secret Name'), findsNothing);
      expect(find.textContaining('tablet'), findsNothing);
    });

    testWidgets('names the other time zone and the last sync hour',
        (tester) async {
      await _open(
        tester,
        ownerLastSeenAt: DateTime.utc(2026, 10, 16, 5),
      );

      expect(find.byKey(const Key('profile-zone-note')), findsOneWidget);
      expect(find.textContaining('Europe/Berlin'), findsOneWidget);
      // 05:00 UTC is 09:00 on the device (UTC+4): the hour, in the viewer's
      // zone.
      expect(find.byKey(const Key('profile-last-sync-note')), findsOneWidget);
      expect(find.textContaining('09:00'), findsOneWidget);
    });
  });

  group('editor', () {
    testWidgets('may add medications but never marks doses', (tester) async {
      final day = await _open(tester, role: 'editor');

      expect(find.byKey(const Key('today-add')), findsOneWidget);
      expect(find.byKey(ValueKey('dose-take-${day.morning}')), findsNothing);
      expect(find.byKey(ValueKey('dose-missed-${day.morning}')), findsNothing);
      expect(
          find.byKey(ValueKey('dose-status-${day.morning}')), findsOneWidget);
    });
  });

  group('guardian', () {
    testWidgets('marks doses of a managed profile in its own zone',
        (tester) async {
      final day = await _open(
        tester,
        role: 'guardian',
        kind: 'managed',
        zone: 'Europe/Moscow',
      );

      // 06:00 UTC is 09:00 in Moscow: the 08:00 dose there is an hour late,
      // and a guardian can still mark it.
      expect(
          find.byKey(ValueKey('dose-missed-${day.morning}')), findsOneWidget);
      expect(find.byKey(ValueKey('dose-status-${day.morning}')), findsNothing);
      expect(find.byKey(const Key('today-add')), findsOneWidget);
    });
  });

  group('archive (D1)', () {
    testWidgets('pending deletion: read-only with the explanation',
        (tester) async {
      final day = await _open(
        tester,
        role: 'guardian',
        kind: 'managed',
        archived: true,
      );

      expect(find.byKey(const Key('archive-banner')), findsOneWidget);
      expect(find.textContaining('being deleted'), findsOneWidget);
      expect(find.byKey(const Key('today-add')), findsNothing);
      expect(find.byKey(ValueKey('dose-take-${day.morning}')), findsNothing);
      expect(find.byKey(const Key('archive-purge')), findsNothing);
      expect(find.byKey(const Key('archive-leave')), findsOneWidget);
    });

    testWidgets('after the owner was erased: the purge date and a purge',
        (tester) async {
      await _open(
        tester,
        role: 'guardian',
        kind: 'managed',
        archived: true,
        purgeAfter: DateTime.utc(2026, 12, 1),
      );

      expect(find.textContaining('Dec 1, 2026'), findsOneWidget);
      expect(find.byKey(const Key('archive-purge')), findsOneWidget);
    });
  });
}
