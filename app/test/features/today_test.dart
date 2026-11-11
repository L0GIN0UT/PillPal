import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/features/pharmacies/pharmacy_providers.dart';
import 'package:pillpal/src/features/today/dose_tile.dart';
import 'package:pillpal/src/features/today/today_widgets.dart';

import '../helpers.dart';
import 'fake_url_opener.dart';

/// Seeds "Med A 500 mg" daily at 08:00 and 20:00; returns the schedule id.
Future<({String medication, String schedule})> _seedDaily(
  TestHarness harness,
  ProviderContainer container,
) async {
  await harness.seedSelfProfile();
  final medication = await harness.seedMedication(
    container,
    name: 'Med A',
    strength: '500 mg',
  );
  final schedule = await harness.seedSchedule(
    container,
    medication,
    testRule(times: ['08:00', '20:00']),
  );
  return (medication: medication, schedule: schedule);
}

/// "Taken N of M" as the ring of the header says it.
({int done, int total}) _progress(WidgetTester tester) {
  final ring =
      tester.widget<ProgressRing>(find.byKey(const Key('today-summary')));
  return (done: ring.done, total: ring.total);
}

DoseTileLayout _layoutOf(WidgetTester tester, String key) =>
    tester.widget<DoseTile>(find.byKey(ValueKey(key))).layout;

void main() {
  testWidgets('shows statuses, takes a dose and undoes it', (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    final ids = await _seedDaily(harness, container);
    final morning = '${ids.schedule}/2026-10-16T08:00';
    final evening = '${ids.schedule}/2026-10-16T20:00';

    await pumpApp(tester, harness: harness, container: container);

    expect(find.text('Friday, October 16'), findsOneWidget);
    expect(find.text('Med A 500 mg'), findsNWidgets(2));
    // 10:00 local: the 08:00 dose is overdue by more than 30 minutes.
    expect(find.byKey(ValueKey('dose-missed-$morning')), findsOneWidget);
    expect(find.byKey(ValueKey('dose-take-$evening')), findsOneWidget);
    expect(_progress(tester), (done: 0, total: 2));
    expect(harness.syncCalls, greaterThan(0));
    // The dose to take is the «Сейчас» card, the missed one is among the
    // earlier ones; each is a single tile.
    expect(_layoutOf(tester, evening), DoseTileLayout.hero);
    expect(_layoutOf(tester, morning), DoseTileLayout.past);
    expect(find.byType(DoseTile), findsNWidgets(2));

    await tester.tap(find.byKey(ValueKey('dose-take-$evening')));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('dose-taken-$evening')), findsOneWidget);
    expect(_progress(tester), (done: 1, total: 2));
    // A taken dose moves to «Earlier today», below its header.
    expect(_layoutOf(tester, evening), DoseTileLayout.past);
    expect(
      tester.getTopLeft(find.byKey(ValueKey('dose-taken-$evening'))).dy,
      greaterThan(tester.getBottomLeft(find.text('Earlier today')).dy),
    );
    expect(find.byType(DoseTile), findsNWidgets(2));
    final events = await harness.db.select(harness.db.doseEvents).get();
    expect(events.single.eventType, 'taken');
    expect(events.single.occurrenceKey, evening);
    expect(events.single.medicationId, ids.medication);

    // Undo through the dose's action sheet.
    await tester.tap(find.byKey(ValueKey(evening)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dose-sheet-undo')));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('dose-take-$evening')), findsOneWidget);
    expect(_progress(tester), (done: 0, total: 2));
  });

  testWidgets('a missed dose can be skipped or taken late', (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    final ids = await _seedDaily(harness, container);
    final morning = '${ids.schedule}/2026-10-16T08:00';
    await pumpApp(tester, harness: harness, container: container);

    await tester.longPress(find.byKey(ValueKey(morning)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dose-sheet-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('dose-skipped-$morning')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey(morning)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dose-sheet-undo')));
    await tester.pumpAndSettle();
    // "Missed" asks whether it was taken or skipped.
    await tester.tap(find.byKey(ValueKey('dose-missed-$morning')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dose-sheet-skip')), findsOneWidget);
    await tester.tap(find.byKey(const Key('dose-sheet-take')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('dose-taken-$morning')), findsOneWidget);
  });

  testWidgets('a double tap records one event; undo makes it pending again',
      (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    final ids = await _seedDaily(harness, container);
    final evening = '${ids.schedule}/2026-10-16T20:00';
    await pumpApp(tester, harness: harness, container: container);

    final take = find.byKey(ValueKey('dose-take-$evening'));
    await tester.tap(take);
    await tester.tap(take);
    await tester.pumpAndSettle();

    var events = await harness.db.select(harness.db.doseEvents).get();
    expect(events.map((e) => e.eventType), ['taken']);
    expect(find.byKey(ValueKey('dose-taken-$evening')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey(evening)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dose-sheet-undo')));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('dose-take-$evening')), findsOneWidget);
    events = await harness.db.select(harness.db.doseEvents).get();
    expect(events.map((e) => e.eventType), ['taken', 'undo']);
  });

  testWidgets('all taken shows the completed summary', (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    final ids = await _seedDaily(harness, container);
    await pumpApp(tester, harness: harness, container: container);

    for (final time in ['08:00', '20:00']) {
      final key = '${ids.schedule}/2026-10-16T$time';
      // The name opens the actions on every look of the tile, the «Сейчас»
      // card included (its middle is a button).
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.text('Med A 500 mg'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dose-sheet-take')));
      await tester.pumpAndSettle();
    }

    expect(find.text('All taken for today'), findsOneWidget);
  });

  testWidgets('low stock banner and as-needed intake', (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final vitamin = await harness.seedMedication(
      container,
      name: 'Vitamin X',
      stockCount: '5',
      stockUnit: 'tablet',
    );
    await harness.seedSchedule(container, vitamin, testRule());
    final spray = await harness.seedMedication(container, name: 'Spray Y');
    await harness.seedSchedule(
      container,
      spray,
      testRule(kind: 'as_needed', times: const []),
    );
    await pumpApp(tester, harness: harness, container: container);

    expect(
      find.text('Vitamin X is running low: 5 days left'),
      findsOneWidget,
    );
    expect(find.text('As needed'), findsOneWidget);
    expect(find.text('Not taken today'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('as-needed-$spray')));
    await tester.pumpAndSettle();

    expect(find.text('Today: once, at 10:00'), findsOneWidget);
    final events = await harness.db.select(harness.db.doseEvents).get();
    expect(events.single.occurrenceKey, isNull);
    expect(events.single.medicationId, spray);

    await tester.tap(find.byKey(ValueKey('as-needed-undo-$spray')));
    await tester.pumpAndSettle();
    expect(find.text('Not taken today'), findsOneWidget);
    expect(find.byKey(ValueKey('as-needed-undo-$spray')), findsNothing);
  });

  testWidgets('pharmacies tell when no maps app could be opened',
      (tester) async {
    final harness = TestHarness();
    final opener = FakeUrlOpener();
    final container = createContainer(
      harness,
      overrides: [urlOpenerProvider.overrideWithValue(opener)],
    );
    await harness.seedSelfProfile();
    final vitamin = await harness.seedMedication(
      container,
      name: 'Vitamin X',
      stockCount: '2',
      stockUnit: 'tablet',
    );
    await harness.seedSchedule(container, vitamin, testRule());
    await pumpApp(tester, harness: harness, container: container);

    await tester.tap(find.text('Pharmacies'));
    await tester.pumpAndSettle();

    expect(opener.opened.map((uri) => uri.scheme), ['geo', 'https']);
    expect(find.text("Couldn't open maps"), findsOneWidget);
  });

  testWidgets('Berlin on the DST change day, with a New York medication',
      (tester) async {
    // 2026-10-25 10:00 in Berlin, an hour after summer time ended.
    final harness = TestHarness(
      zone: 'Europe/Berlin',
      now: DateTime.utc(2026, 10, 25, 9),
    );
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final local = await harness.seedMedication(container, name: 'Med A');
    final localSchedule = await harness.seedSchedule(
      container,
      local,
      testRule(times: ['08:00', '20:00']),
    );
    final fixed = await container.read(medicationsRepositoryProvider).create(
          profileId: selfProfileId,
          draft: const MedicationDraft(
            name: 'Med F',
            tzMode: 'fixed',
            fixedTz: 'America/New_York',
          ),
        );
    final fixedSchedule = await harness.seedSchedule(
      container,
      fixed,
      testRule(times: ['20:00']),
    );
    await pumpApp(tester, harness: harness, container: container);

    expect(find.text('Sunday, October 25'), findsOneWidget);
    // 20:00 in New York on Oct 24 is 02:00 in Berlin on Oct 25 (summer
    // time); its key keeps the New York date.
    final fixedKey = '$fixedSchedule/2026-10-24T20:00';
    expect(
      find.descendant(
        of: find.byKey(ValueKey(fixedKey)),
        matching: find.textContaining('02:00'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('dose-missed-$localSchedule/2026-10-25T08:00')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('dose-take-$localSchedule/2026-10-25T20:00')),
      findsOneWidget,
    );
    expect(_progress(tester), (done: 0, total: 3));

    await tester.tap(find.byKey(ValueKey(fixedKey)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dose-sheet-take')));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('dose-taken-$fixedKey')), findsOneWidget);
    expect(_progress(tester), (done: 1, total: 3));
    final events = await harness.db.select(harness.db.doseEvents).get();
    expect(events.single.occurrenceKey, fixedKey);
  });
}
