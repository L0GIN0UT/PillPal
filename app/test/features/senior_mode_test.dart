import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

  Future<void> pumpSenior(WidgetTester tester) async {
    harness = TestHarness();
    container = createContainer(harness);
    await harness.seedSelfProfile();
    medication = await harness.seedMedication(
      container,
      name: 'Длинное название лекарства',
      strength: '500 мг',
      stockCount: '3',
    );
    schedule = await harness.seedSchedule(
      container,
      medication,
      testRule(times: ['08:00', '14:00', '20:00']),
    );
    final spray = await harness.seedMedication(container, name: 'Спрей');
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
  });

  testWidgets('history and settings fit', (tester) async {
    await pumpSenior(tester);

    await tester.tap(find.text('История'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('day-2026-10-15')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await visit(tester, AppRoutes.settings);
    expect(find.byKey(const Key('sign-out')), findsOneWidget);
  });
}
