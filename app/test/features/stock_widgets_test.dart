import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/pharmacies/pharmacy_providers.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'fake_url_opener.dart';

/// "Med S": 3 tablets left, one tablet at 08:00 and 20:00 (1 day left).
Future<({ProviderContainer container, String medication, String schedule})>
    _seedLowStock(TestHarness harness, FakeUrlOpener opener) async {
  final container = createContainer(
    harness,
    overrides: [urlOpenerProvider.overrideWithValue(opener)],
  );
  await harness.seedSelfProfile();
  final medication = await harness.seedMedication(
    container,
    name: 'Med S',
    stockCount: '3',
    stockUnit: 'tablet',
  );
  final schedule = await harness.seedSchedule(
    container,
    medication,
    testRule(times: ['08:00', '20:00']),
  );
  return (container: container, medication: medication, schedule: schedule);
}

void main() {
  testWidgets('a taken dose lowers the stock; the banner opens pharmacies',
      (tester) async {
    final harness = TestHarness();
    final opener = FakeUrlOpener(handled: {'geo'});
    final seeded = await _seedLowStock(harness, opener);
    await pumpApp(tester, harness: harness, container: seeded.container);

    final banner = find.byKey(ValueKey('low-stock-${seeded.medication}'));
    expect(banner, findsOneWidget);
    expect(find.text('Med S is running low: 1 day left'), findsOneWidget);

    await tester.tap(
      find.byKey(ValueKey('low-stock-pharmacies-${seeded.medication}')),
    );
    await tester.pumpAndSettle();
    expect(opener.opened.single.scheme, 'geo');
    expect(opener.opened.single.queryParameters['q'], 'pharmacy');

    // A dose taken after the count is subtracted (never a synced counter).
    harness.now = harness.now.add(const Duration(minutes: 1));
    await tester.tap(
      find.byKey(ValueKey('dose-take-${seeded.schedule}/2026-10-16T20:00')),
    );
    await tester.pumpAndSettle();
    openRoute(seeded.container, AppRoutes.medication(seeded.medication));
    await tester.pumpAndSettle();
    expect(
      find.text('Left: 2 tablets · for 1 day'),
      findsOneWidget,
    );
    final row = (await harness.db.select(harness.db.medications).get()).single;
    expect(row.stockCount, '3', reason: 'the count itself never changes');
  });

  testWidgets('restocking sets a new baseline and clears the banner',
      (tester) async {
    final harness = TestHarness();
    final seeded = await _seedLowStock(harness, FakeUrlOpener());
    await pumpApp(tester, harness: harness, container: seeded.container);
    harness.now = harness.now.add(const Duration(hours: 1));

    await tester.tap(
      find.byKey(ValueKey('low-stock-refill-${seeded.medication}')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('refill-count')), 'lots');
    await tester.tap(find.byKey(const Key('refill-save')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a number'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('refill-count')), '60,5');
    await tester.tap(find.byKey(const Key('refill-save')));
    await tester.pumpAndSettle();

    final row = (await harness.db.select(harness.db.medications).get()).single;
    expect(row.stockCount, '60.5');
    expect(row.stockUnit, 'tablet');
    expect(row.stockSetAt, harness.now.microsecondsSinceEpoch);
    expect(
      find.byKey(ValueKey('low-stock-${seeded.medication}')),
      findsNothing,
    );
    expect(harness.syncCalls, greaterThan(0));
  });

  testWidgets('saving the medication form keeps the stock baseline',
      (tester) async {
    final harness = TestHarness();
    final seeded = await _seedLowStock(harness, FakeUrlOpener());
    final before = (await harness.db.select(harness.db.medications).get())
        .single
        .stockSetAt;
    await pumpApp(tester, harness: harness, container: seeded.container);
    harness.now = harness.now.add(const Duration(days: 1));

    openRoute(seeded.container, AppRoutes.medication(seeded.medication));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('med-stock-count')), findsNothing);
    expect(find.byKey(const Key('med-stock-refill')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('med-notes')), 'with food');
    await tester.tap(find.byKey(const Key('med-save')));
    await tester.pumpAndSettle();

    final row = (await harness.db.select(harness.db.medications).get()).single;
    expect(row.notes, 'with food');
    expect(row.stockCount, '3');
    expect(row.stockSetAt, before);
  });

  testWidgets('a stock in another unit than the doses is not computed',
      (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final medication = await harness.seedMedication(
      container,
      name: 'Syrup',
      stockCount: '100',
      stockUnit: 'ml',
    );
    await harness.seedSchedule(container, medication, testRule());
    await pumpApp(tester, harness: harness, container: container);

    expect(find.byKey(ValueKey('low-stock-$medication')), findsNothing);
    openRoute(container, AppRoutes.medication(medication));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "Can't compute what is left: the doses use another unit than the "
        'stock',
      ),
      findsOneWidget,
    );
  });
}
