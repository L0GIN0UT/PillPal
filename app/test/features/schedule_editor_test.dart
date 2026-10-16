import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';

/// Opens the editor for a new schedule of a fresh medication.
Future<({TestHarness harness, String medication})> _openEditor(
  WidgetTester tester,
) async {
  final harness = TestHarness();
  final container = createContainer(harness);
  await harness.seedSelfProfile();
  final medication = await harness.seedMedication(container, name: 'Med S');
  await pumpApp(tester, harness: harness, container: container);
  openRoute(container, AppRoutes.newSchedule(medication));
  await tester.pumpAndSettle();
  return (harness: harness, medication: medication);
}

Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

/// Saves and returns the stored rule.
Future<Map<String, Object?>> _saveAndRead(
  WidgetTester tester,
  TestHarness harness,
) async {
  await _tap(tester, const Key('schedule-save'));
  final rows = await harness.db.select(harness.db.schedules).get();
  return jsonDecode(rows.single.rule) as Map<String, Object?>;
}

Map<String, Object?> _slot(String time, String amount, String unit) => {
      'time': time,
      'dose': {'amount': amount, 'unit': unit},
    };

void main() {
  testWidgets('daily: two times, edited dose and unit', (tester) async {
    final env = await _openEditor(tester);
    expect(find.text('Med S'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('slot-amount-08:00')),
      '0,5',
    );
    await _tap(tester, const Key('slot-add'));
    await _tap(tester, const ValueKey('slot-unit-12:00'));
    await tester.tap(find.byKey(const ValueKey('unit-capsule')).last);
    await tester.pumpAndSettle();

    final rule = await _saveAndRead(tester, env.harness);
    expect(rule, {
      'v': 1,
      'kind': 'daily',
      'start_date': '2026-10-16',
      'end_date': null,
      'times': [
        _slot('08:00', '0.5', 'tablet'),
        _slot('12:00', '0.5', 'capsule'),
      ],
    });
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('weekdays: chosen days are saved', (tester) async {
    final env = await _openEditor(tester);

    await _tap(tester, const ValueKey('kind-weekdays'));
    await _tap(tester, const ValueKey('weekday-1'));
    await _tap(tester, const ValueKey('weekday-3'));

    final rule = await _saveAndRead(tester, env.harness);
    expect(rule['kind'], 'weekdays');
    expect(rule['weekdays'], [1, 3, 5]);
    expect(rule['times'], [_slot('08:00', '1', 'tablet')]);
  });

  testWidgets('weekdays: no day selected is refused', (tester) async {
    final env = await _openEditor(tester);

    await _tap(tester, const ValueKey('kind-weekdays'));
    await _tap(tester, const ValueKey('weekday-5')); // deselect Friday
    await _tap(tester, const Key('schedule-save'));

    expect(find.text('Choose at least one day.'), findsOneWidget);
    expect(
        await env.harness.db.select(env.harness.db.schedules).get(), isEmpty);
  });

  testWidgets('interval: every 3 days', (tester) async {
    final env = await _openEditor(tester);

    await _tap(tester, const ValueKey('kind-interval_days'));
    expect(find.text('Every 2 days'), findsOneWidget);
    await _tap(tester, const Key('interval-plus'));
    expect(find.text('Every 3 days'), findsOneWidget);

    final rule = await _saveAndRead(tester, env.harness);
    expect(rule['kind'], 'interval_days');
    expect(rule['interval_days'], 3);
    expect(rule.containsKey('weekdays'), isFalse);
  });

  testWidgets('as needed: no times', (tester) async {
    final env = await _openEditor(tester);

    await _tap(tester, const ValueKey('kind-as_needed'));
    expect(find.byKey(const Key('slot-add')), findsNothing);

    final rule = await _saveAndRead(tester, env.harness);
    expect(rule, {
      'v': 1,
      'kind': 'as_needed',
      'start_date': '2026-10-16',
      'end_date': null,
      'times': <Object?>[],
    });
  });

  testWidgets('an invalid dose is refused', (tester) async {
    final env = await _openEditor(tester);

    await tester.enterText(
      find.byKey(const ValueKey('slot-amount-08:00')),
      '0',
    );
    await _tap(tester, const Key('schedule-save'));

    expect(
      find.text('Dose: a number greater than zero, up to 3 decimals.'),
      findsOneWidget,
    );
    expect(
        await env.harness.db.select(env.harness.db.schedules).get(), isEmpty);
  });

  testWidgets('editing an existing schedule keeps its id', (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final medication = await harness.seedMedication(container);
    final schedule = await harness.seedSchedule(
      container,
      medication,
      testRule(times: ['09:00']),
    );
    await pumpApp(tester, harness: harness, container: container);
    openRoute(container, AppRoutes.schedule(medication, schedule));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('slot-time-09:00')), findsOneWidget);
    await _tap(tester, const ValueKey('kind-weekdays'));
    await _tap(tester, const ValueKey('weekday-2'));
    final rule = await _saveAndRead(tester, harness);

    expect(rule['weekdays'], [2, 4]); // 2026-10-01 is a Thursday
    expect(rule['start_date'], '2026-10-01');
    final rows = await harness.db.select(harness.db.schedules).get();
    expect(rows.single.id, schedule);
  });
}
