import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// The History of a relative is built from the server's projection: an
// anonymous medication is a generic one there too (ADR 0005 §2).

void main() {
  testWidgets('an anonymous medication has no name or dose in History',
      (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final profile = await seedProfile(harness, name: 'Grace');
    await seedForeignMedication(
      harness,
      container,
      profile,
      name: 'Secret Name',
      strength: '500 mg',
      privacy: 'anonymous',
      redacted: true,
      leakDoses: true,
    );
    await pumpApp(tester, harness: harness, container: container);
    openRoute(container, AppRoutes.profileHistory(profile));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('day-2026-10-16')));
    await tester.pumpAndSettle();

    final day = find.byKey(const Key('history-day'));
    expect(day, findsOneWidget);
    expect(
      find.descendant(of: day, matching: find.text('Medication')),
      findsOneWidget,
    );
    expect(find.textContaining('Secret Name'), findsNothing);
    expect(find.textContaining('500'), findsNothing);
    expect(find.textContaining('tablet'), findsNothing);
  });

  testWidgets('a shared medication is named in History', (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final profile = await seedProfile(harness, name: 'Grace');
    await seedForeignMedication(
      harness,
      container,
      profile,
      name: 'Shared Med',
    );
    await pumpApp(tester, harness: harness, container: container);
    openRoute(container, AppRoutes.profileHistory(profile));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('day-2026-10-16')));
    await tester.pumpAndSettle();

    expect(find.text('Shared Med'), findsOneWidget);
  });

  testWidgets('the list of medications shows no name or strength either',
      (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final profile = await seedProfile(harness, name: 'Grace');
    await seedForeignMedication(
      harness,
      container,
      profile,
      name: 'Secret Name',
      strength: '500 mg',
      privacy: 'anonymous',
      redacted: true,
      leakDoses: true,
    );
    await pumpApp(tester, harness: harness, container: container);
    openRoute(container, AppRoutes.profileMedications(profile));
    await tester.pumpAndSettle();

    expect(find.text('Medication'), findsOneWidget);
    expect(find.textContaining('Secret Name'), findsNothing);
    expect(find.textContaining('500'), findsNothing);
  });
}
