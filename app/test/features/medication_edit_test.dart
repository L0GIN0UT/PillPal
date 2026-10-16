import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/medications/medication_form.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';

Future<void> _openNewMedication(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('today-add')));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('med-save')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('name is required; saving opens the schedule editor',
      (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    await pumpApp(tester, harness: harness, container: container);
    await _openNewMedication(tester);

    expect(find.text('New medication'), findsOneWidget);
    // Phase 4 entry points are visible but disabled.
    final scan = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Scan the package — soon'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    expect(scan.onPressed, isNull);

    await _save(tester);
    expect(find.text('Required'), findsOneWidget);
    expect(await harness.db.select(harness.db.medications).get(), isEmpty);

    await tester.enterText(find.byKey(const Key('med-name')), 'Med B');
    await tester.enterText(find.byKey(const Key('med-strength')), '20 mg');
    await tester.enterText(find.byKey(const Key('med-notes')), 'with food');
    await tester.tap(find.byKey(const ValueKey('privacy-anonymous')));
    await tester.pump();
    await _save(tester);

    final rows = await harness.db.select(harness.db.medications).get();
    expect(rows.single.name, 'Med B');
    expect(rows.single.strengthText, '20 mg');
    expect(rows.single.notes, 'with food');
    expect(rows.single.privacy, 'anonymous');
    expect(rows.single.tzMode, 'local');
    expect(rows.single.profileId, selfProfileId);
    expect(find.byKey(const Key('schedule-save')), findsOneWidget);
    expect(harness.syncCalls, greaterThan(0));
  });

  testWidgets('fixed zone and stock are validated', (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    await pumpApp(tester, harness: harness, container: container);
    await _openNewMedication(tester);

    await tester.enterText(find.byKey(const Key('med-name')), 'Med C');
    await tester.tap(find.byKey(const Key('med-zone-switch')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('med-zone')), 'Mars/Base');
    await tester.tap(find.byKey(const Key('med-stock-switch')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('med-stock-count')), 'many');
    await _save(tester);

    expect(
      find.text('Unknown time zone, e.g. Europe/Moscow'),
      findsOneWidget,
    );
    expect(find.text('Enter a number'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('med-zone')), 'Asia/Tokyo');
    await tester.enterText(find.byKey(const Key('med-stock-count')), '12,5');
    await _save(tester);

    final row = (await harness.db.select(harness.db.medications).get()).single;
    expect(row.tzMode, 'fixed');
    expect(row.fixedTz, 'Asia/Tokyo');
    expect(row.stockCount, '12.5');
  });

  testWidgets('editing updates the row and lists its schedules',
      (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final id = await harness.seedMedication(container, name: 'Med D');
    await harness.seedSchedule(container, id, testRule(times: ['09:00']));
    await pumpApp(tester, harness: harness, container: container);

    openRoute(container, AppRoutes.medication(id));
    await tester.pumpAndSettle();

    expect(find.text('Every day · 09:00'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('med-name')), 'Med D2');
    await _save(tester);

    final row = (await harness.db.select(harness.db.medications).get()).single;
    expect(row.name, 'Med D2');
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('deleting asks for confirmation', (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final id = await harness.seedMedication(container, name: 'Med E');
    await pumpApp(tester, harness: harness, container: container);
    openRoute(container, AppRoutes.medication(id));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('med-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pumpAndSettle();

    final row = (await harness.db.select(harness.db.medications).get()).single;
    expect(row.deletedAt, isNotNull);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  test('form input validation and draft mapping', () {
    const valid = MedicationFormInput(
      name: '  Med F ',
      privacy: MedicationPrivacy.hidden,
      trackStock: true,
      stockCount: '30',
      stockUnit: 'pcs',
      lowStockDays: '5',
    );
    expect(valid.validate(), isEmpty);
    final draft = valid.toDraft();
    expect(draft.name, 'Med F');
    expect(draft.privacy, 'hidden');
    expect(draft.stockCount, '30');
    expect(draft.lowStockDays, 5);
    expect(draft.fixedTz, isNull);

    const invalid = MedicationFormInput(
      trackStock: true,
      stockCount: '1.2345',
      lowStockDays: '400',
    );
    expect(invalid.validate(), {
      MedicationField.medicationName: MedicationFormErrors.required,
      MedicationField.stockCount: MedicationFormErrors.invalidNumber,
      MedicationField.lowStockDays: MedicationFormErrors.invalidNumber,
    });
  });
}
