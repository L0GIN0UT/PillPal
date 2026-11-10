import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// D4 (docs/redesign-plan.md): the privacy of a medication, edited on the
// relative screen, applies to every relative and goes through the same write
// as the medication form: one outbox entry, the same fields.

Key _level(String medicationId, String level) =>
    ValueKey('relative-privacy-$medicationId-$level');

Future<List<OutboxEntry>> _entriesOf(TestHarness harness, String id) async {
  final all = await harness.db.select(harness.db.outbox).get();
  return [
    for (final entry in all)
      if (entry.entityId == id) entry,
  ];
}

Map<String, Object?> _payload(OutboxEntry entry) =>
    jsonDecode(entry.payload!) as Map<String, Object?>;

Future<void> _open(
  WidgetTester tester,
  TestHarness harness,
  ProviderContainer container,
  String linkId,
) async {
  await pumpApp(tester, harness: harness, container: container);
  openRoute(container, AppRoutes.link(linkId));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a level change writes the same update as the form',
      (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    await seedLink(harness, id: 'out-1');
    // Two equal medications: one is changed in the form, the other on the
    // relative screen.
    final viaForm = await harness.seedMedication(
      container,
      name: 'Med A',
      strength: '10 mg',
      stockCount: '12',
      stockUnit: 'tablet',
    );
    final viaRelative = await harness.seedMedication(
      container,
      name: 'Med A',
      strength: '10 mg',
      stockCount: '12',
      stockUnit: 'tablet',
    );
    await pumpApp(tester, harness: harness, container: container);

    openRoute(container, AppRoutes.medication(viaForm));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('privacy-hidden')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('med-save')));
    await tester.pumpAndSettle();

    openRoute(container, AppRoutes.link('out-1'));
    await tester.pumpAndSettle();
    final before = (await _entriesOf(harness, viaRelative)).length;
    await tester.tap(find.byKey(_level(viaRelative, 'hidden')));
    await tester.pumpAndSettle();

    final entries = await _entriesOf(harness, viaRelative);
    expect(entries.length, before + 1, reason: 'one outbox entry per change');
    final fromForm = _payload((await _entriesOf(harness, viaForm)).last);
    final fromRelative = _payload(entries.last);
    expect(fromRelative['privacy'], 'hidden');
    expect(fromRelative, fromForm);
    expect(entries.last.op, 'upsert');
    expect(harness.syncCalls, greaterThan(0));
  });

  testWidgets('shows the level and says it applies to all relatives',
      (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    await seedLink(harness, id: 'out-1');
    final shared = await harness.seedMedication(container, name: 'Med A');
    final anonymous = await harness.seedMedication(
      container,
      name: 'Med B',
      privacy: 'anonymous',
    );
    await _open(tester, harness, container, 'out-1');

    expect(find.text('This applies to all your relatives'), findsOneWidget);
    expect(find.text('Med A'), findsOneWidget);
    expect(find.text('Med B'), findsOneWidget);
    for (final level in ['shared', 'anonymous', 'hidden']) {
      expect(find.byKey(_level(shared, level)), findsOneWidget);
      expect(find.byKey(_level(anonymous, level)), findsOneWidget);
    }

    await tester.tap(find.byKey(_level(anonymous, 'shared')));
    await tester.pumpAndSettle();
    final rows = await harness.db.select(harness.db.medications).get();
    expect(
      rows.firstWhere((row) => row.id == anonymous).privacy,
      'shared',
    );
    // Only the touched medication was written.
    expect((await _entriesOf(harness, shared)).length, 1);
  });

  testWidgets('a relative never sees the editor', (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    // Someone else's profile that the account only follows, and a medication
    // of it that the server projected for a viewer.
    await seedProfile(harness, role: 'viewer');
    await seedLink(
      harness,
      id: 'in-1',
      direction: LinkDirection.incoming,
      profileId: 'foreign-profile-1',
    );
    await harness.db.into(harness.db.medications).insert(
          const MedicationRow(
            id: 'foreign-med-1',
            profileId: 'foreign-profile-1',
            name: 'Foreign Med',
            tzMode: 'local',
            privacy: 'shared',
            redacted: false,
            clientUpdatedAt: 1,
            updatedByDevice: 'other',
            gtinLinkShared: false,
          ),
        );
    await _open(tester, harness, container, 'in-1');

    expect(find.byKey(const Key('notify-missed')), findsOneWidget);
    expect(find.text('This applies to all your relatives'), findsNothing);
    for (final level in ['shared', 'anonymous', 'hidden']) {
      expect(find.byKey(_level('foreign-med-1', level)), findsNothing);
    }
  });

  testWidgets('a guardian link has no editor', (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    await seedLink(harness, id: 'out-1', role: 'guardian');
    final id = await harness.seedMedication(container, name: 'Med A');
    await _open(tester, harness, container, 'out-1');

    // A guardian sees everything whatever the level: nothing to choose here.
    expect(find.byKey(_level(id, 'hidden')), findsNothing);
  });
}
