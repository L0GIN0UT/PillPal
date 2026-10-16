import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/routing/routes.dart';
import 'package:pillpal/src/settings/app_settings.dart';

import '../helpers.dart';

/// Every main screen in senior mode (text x1.3, large buttons), dark theme
/// and Russian (the longer language) must lay out without overflow.
void main() {
  late TestHarness harness;
  late ProviderContainer container;
  late String medication;
  late String schedule;
  late String spray;

  Future<void> pumpSenior(WidgetTester tester) async {
    harness = TestHarness();
    container = createContainer(harness);
    await harness.seedSelfProfile();
    medication = await harness.seedMedication(
      container,
      name: 'Длинное название лекарства',
      strength: '500 мг',
      stockCount: '3',
      stockUnit: 'tablet',
    );
    schedule = await harness.seedSchedule(
      container,
      medication,
      testRule(times: ['08:00', '14:00', '20:00']),
    );
    spray = await harness.seedMedication(container, name: 'Спрей');
    await harness.seedSchedule(
      container,
      spray,
      testRule(kind: 'as_needed', times: const []),
    );
    await pumpApp(
      tester,
      harness: harness,
      container: container,
      locale: const Locale('ru'),
      configure: (scope) {
        scope.read(settingsProvider.notifier)
          ..setSeniorMode(enabled: true)
          ..setThemeMode(ThemeMode.dark);
      },
    );
  }

  Future<void> visit(WidgetTester tester, String location) async {
    openRoute(container, location);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('Today uses the large "take now" card', (tester) async {
    await pumpSenior(tester);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('senior-now')), findsOneWidget);
    expect(find.text('Сейчас пора принять'), findsOneWidget);
    final take = tester.getSize(
      find.byKey(ValueKey('dose-take-$schedule/2026-10-16T08:00')),
    );
    expect(take.height, greaterThanOrEqualTo(64));

    await tester.tap(find.byKey(const Key('senior-snooze')));
    await tester.pump();
    expect(find.text('Отложено'), findsOneWidget);

    // As-needed button: a senior-sized touch target too.
    final intake = tester.getSize(find.byKey(ValueKey('as-needed-$spray')));
    expect(intake.height, greaterThanOrEqualTo(64));
  });

  testWidgets('skip the missed dose, take the next one, undo it',
      (tester) async {
    await pumpSenior(tester);
    final morning = '$schedule/2026-10-16T08:00';
    final noon = '$schedule/2026-10-16T14:00';

    // 10:00: the 08:00 dose is missed, 14:00 is next.
    await tester.tap(find.byKey(const Key('senior-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('senior-confirmation')), findsOneWidget);
    await tester.pump(DoseTiming.confirmation);
    await tester.pumpAndSettle();

    expect(find.text('Следующий приём'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('dose-take-$noon')));
    // Short steps (not pumpAndSettle): the undo guard must still be on.
    for (var i = 0; i < 6 && find.text('Принято ✓').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Принято ✓'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final events = await harness.db.select(harness.db.doseEvents).get();
    expect(
      {for (final e in events) e.occurrenceKey: e.eventType},
      {morning: 'skipped', noon: 'taken'},
    );

    // A tap right after the confirmation appears is ignored...
    await tester.tap(find.byKey(const Key('senior-undo')));
    await tester.pump();
    expect(find.byKey(const Key('senior-confirmation')), findsOneWidget);
    expect(
      (await harness.db.select(harness.db.doseEvents).get())
          .where((e) => e.eventType == 'undo'),
      isEmpty,
    );
    // ...a deliberate one after the guard undoes the mark.
    await tester.pump(DoseTiming.undoGuard);
    await tester.tap(find.byKey(const Key('senior-undo')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('dose-take-$noon')), findsOneWidget);
  });

  testWidgets('a time group opens the take/skip sheet', (tester) async {
    await pumpSenior(tester);

    await tester.tap(find.byKey(const ValueKey('senior-group-20:00')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dose-sheet-take')));
    await tester.pumpAndSettle();

    final events = await harness.db.select(harness.db.doseEvents).get();
    expect(events.single.occurrenceKey, '$schedule/2026-10-16T20:00');
    expect(events.single.eventType, 'taken');
  });

  testWidgets('medication screens fit', (tester) async {
    await pumpSenior(tester);

    await tester.tap(find.text('Лекарства'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await visit(tester, AppRoutes.newMedication);
    await tester.tap(find.byKey(const Key('med-stock-switch')));
    await tester.tap(find.byKey(const Key('med-zone-switch')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await visit(tester, AppRoutes.medication(medication));
    await visit(tester, AppRoutes.schedule(medication, schedule));
    await tester.tap(find.byKey(const ValueKey('kind-weekdays')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final chip = tester.getSize(find.byKey(const ValueKey('weekday-1')));
    expect(chip.height, greaterThanOrEqualTo(64));
    expect(chip.width, greaterThanOrEqualTo(64));
  });

  testWidgets('history and settings fit', (tester) async {
    await pumpSenior(tester);

    await tester.tap(find.text('История'));
    await tester.pumpAndSettle();
    final cell = tester.getSize(find.byKey(const ValueKey('day-2026-10-15')));
    expect(cell.height, greaterThanOrEqualTo(64));
    await tester.tap(find.byKey(const ValueKey('day-2026-10-15')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await visit(tester, AppRoutes.settings);
    expect(find.byKey(const Key('sign-out')), findsOneWidget);
  });
}
