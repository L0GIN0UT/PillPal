import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

void main() {
  testWidgets('no switcher while there is only the own profile',
      (tester) async {
    final harness = TestHarness();
    await harness.seedSelfProfile();
    await pumpApp(tester, harness: harness);

    expect(find.byKey(const Key('profile-switcher')), findsNothing);
  });

  testWidgets('Today, Medications and History follow the chosen profile',
      (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final own = await harness.seedMedication(container, name: 'Own Med');
    await harness.seedSchedule(container, own, testRule());
    await seedProfile(
      harness,
      id: 'ward-1',
      kind: 'managed',
      role: 'owner',
      name: 'Pat Ward',
    );
    await seedForeignMedication(
      harness,
      container,
      'ward-1',
      name: 'Ward Med',
    );
    await pumpApp(tester, harness: harness, container: container);

    expect(find.byKey(const Key('profile-switcher')), findsOneWidget);
    expect(find.text('Own Med'), findsOneWidget);
    expect(find.text('Ward Med'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('profile-switch-ward-1')));
    await tester.pumpAndSettle();
    expect(find.text('Ward Med'), findsOneWidget);
    expect(find.text('Own Med'), findsNothing);
    // The title names whose day it is.
    expect(find.text('Pat Ward'), findsWidgets);

    await tester.tap(find.byIcon(Icons.medication_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Ward Med'), findsOneWidget);
    expect(find.text('Own Med'), findsNothing);

    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-switcher')), findsOneWidget);

    // Back to "Me" from any tab.
    await tester.tap(find.byKey(const Key('profile-switch-$selfProfileId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.medication_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Own Med'), findsOneWidget);
  });

  testWidgets('a profile that disappears falls back to the own one',
      (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final own = await harness.seedMedication(container, name: 'Own Med');
    await harness.seedSchedule(container, own, testRule());
    await seedProfile(harness, id: 'foreign-1', name: 'Grace');
    await pumpApp(tester, harness: harness, container: container);
    await tester.tap(find.byKey(const ValueKey('profile-switch-foreign-1')));
    await tester.pumpAndSettle();
    expect(find.text('Own Med'), findsNothing);

    // The owner revoked the access: the next pull evicts the scope.
    await (harness.db.delete(harness.db.accessScopes)
          ..where((row) => row.profileId.equals('foreign-1')))
        .go();
    await tester.pumpAndSettle();

    expect(find.text('Own Med'), findsOneWidget);
    expect(find.byKey(const Key('profile-switcher')), findsNothing);
  });
}
