import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/features/history/history_model.dart';
import 'package:pillpal/src/features/history/month_calendar.dart';
import 'package:pillpal/src/features/schedule/schedule_providers.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../helpers.dart';

/// October 2026 fixture (daily 08:00 + 20:00 from Oct 1, now Oct 16 10:00):
/// Oct 1 both taken, Oct 2 none, Oct 3 morning only, Oct 4-15 both taken.
Future<void> _seedOctober(
  TestHarness harness,
  ProviderContainer container,
) async {
  await harness.seedSelfProfile();
  final medication = await harness.seedMedication(container, name: 'Med H');
  final schedule = await harness.seedSchedule(
    container,
    medication,
    testRule(times: ['08:00', '20:00']),
  );
  final events = container.read(doseEventsRepositoryProvider);
  Future<void> take(int day, String time) {
    final hour = int.parse(time.substring(0, 2));
    return events.record(
      medicationId: medication,
      type: DoseEventType.taken,
      // Five minutes after the dose, in UTC+4.
      at: DateTime.utc(2026, 10, day, hour - 4, 5),
      occurrence: OccurrenceRef(
        scheduleId: schedule,
        localDate: LocalDate(2026, 10, day),
        localTime: time,
      ),
    );
  }

  await take(1, '08:00');
  await take(1, '20:00');
  await take(3, '08:00');
  for (var day = 4; day <= 15; day++) {
    await take(day, '08:00');
    await take(day, '20:00');
  }
}

DayAdherence _adherenceOf(WidgetTester tester, String date) {
  final cell = tester.widget<CalendarDayCell>(
    find.byKey(ValueKey('day-$date')),
  );
  return cell.day.adherence;
}

void main() {
  testWidgets('colours days, shows adherence and streak', (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await _seedOctober(harness, container);
    await pumpApp(tester, harness: harness, container: container);

    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();

    expect(find.text('October 2026'), findsOneWidget);
    expect(_adherenceOf(tester, '2026-10-01'), DayAdherence.allTaken);
    expect(_adherenceOf(tester, '2026-10-02'), DayAdherence.missed);
    expect(_adherenceOf(tester, '2026-10-03'), DayAdherence.partial);
    expect(_adherenceOf(tester, '2026-10-15'), DayAdherence.allTaken);
    expect(_adherenceOf(tester, '2026-10-16'), DayAdherence.today);
    expect(_adherenceOf(tester, '2026-10-17'), DayAdherence.future);

    // Due so far: 15 days x 2 + today's missed 08:00 = 31; taken 27.
    expect(find.text('87%'), findsOneWidget);
    expect(find.text('of doses taken in October'), findsOneWidget);
    // Oct 4..15 in a row.
    expect(
      find.descendant(
        of: find.byKey(const Key('history-streak')),
        matching: find.text('12'),
      ),
      findsOneWidget,
    );
    expect(find.text('days in a row without misses'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('day-2026-10-03')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('history-day')), findsOneWidget);
    expect(find.text('Taken at 08:05'), findsOneWidget);
    expect(find.text('Missed'), findsOneWidget);

    // The PDF report arrives in 2.4.
    final pdf = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('PDF report for the doctor'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    expect(pdf.onPressed, isNull);
  });

  testWidgets('Berlin on the DST change day; a late mark still counts',
      (tester) async {
    // 2026-10-25 10:00 in Berlin, an hour after summer time ended.
    final now = DateTime.utc(2026, 10, 25, 9);
    final harness = TestHarness(zone: 'Europe/Berlin', now: now);
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final medication = await harness.seedMedication(container, name: 'Med B');
    final schedule = await harness.seedSchedule(
      container,
      medication,
      testRule(times: ['08:00', '20:00']),
    );
    final events = container.read(doseEventsRepositoryProvider);
    Future<void> take(int day, String time, DateTime at) => events.record(
          medicationId: medication,
          type: DoseEventType.taken,
          at: at,
          occurrence: OccurrenceRef(
            scheduleId: schedule,
            localDate: LocalDate(2026, 10, day),
            localTime: time,
          ),
        );
    // Summer time (UTC+2): five minutes after the dose.
    await take(24, '08:00', DateTime.utc(2026, 10, 24, 6, 5));
    await take(24, '20:00', DateTime.utc(2026, 10, 24, 18, 5));
    await take(23, '08:00', DateTime.utc(2026, 10, 23, 6, 5));
    // Oct 22 evening, marked three days late.
    await take(22, '20:00', now);
    await pumpApp(tester, harness: harness, container: container);

    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();

    expect(_adherenceOf(tester, '2026-10-24'), DayAdherence.allTaken);
    expect(_adherenceOf(tester, '2026-10-23'), DayAdherence.partial);
    expect(_adherenceOf(tester, '2026-10-22'), DayAdherence.partial);
    expect(_adherenceOf(tester, '2026-10-21'), DayAdherence.missed);
    expect(_adherenceOf(tester, '2026-10-25'), DayAdherence.today);
    expect(_adherenceOf(tester, '2026-10-26'), DayAdherence.future);

    await tester.tap(find.byKey(const ValueKey('day-2026-10-24')));
    await tester.pumpAndSettle();
    expect(find.text('Taken at 08:05'), findsOneWidget);
    expect(find.text('Taken at 20:05'), findsOneWidget);
  });

  testWidgets('changing the time keeps past days taken (ADR 0003)',
      (tester) async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final medication = await harness.seedMedication(container, name: 'Med R');
    final schedule = await harness.seedSchedule(
      container,
      medication,
      testRule(),
    );
    await container.read(doseEventsRepositoryProvider).record(
          medicationId: medication,
          type: DoseEventType.taken,
          at: DateTime.utc(2026, 10, 15, 4, 5),
          occurrence: OccurrenceRef(
            scheduleId: schedule,
            localDate: LocalDate(2026, 10, 15),
            localTime: '08:00',
          ),
        );

    await container.read(scheduleServiceProvider).save(
          medicationId: medication,
          scheduleId: schedule,
          rule: testRule(times: ['09:00']),
        );
    await pumpApp(tester, harness: harness, container: container);

    // Today follows the new time.
    expect(find.text('09:00'), findsOneWidget);
    expect(find.text('08:00'), findsNothing);
    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();
    expect(_adherenceOf(tester, '2026-10-15'), DayAdherence.allTaken);
    expect(_adherenceOf(tester, '2026-10-14'), DayAdherence.missed);
  });

  testWidgets('month navigation', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('history-previous')));
    await tester.pumpAndSettle();
    expect(find.text('September 2026'), findsOneWidget);

    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const Key('history-next')));
      await tester.pumpAndSettle();
    }
    expect(find.text('November 2026'), findsOneWidget);
  });

  test('cell colours follow the palette and differ per class', () {
    const palette = PillPalPalette.light;
    expect(dayCellColors(palette, DayAdherence.allTaken).fill, palette.taken);
    expect(dayCellColors(palette, DayAdherence.missed).fill, palette.missed);
    expect(
      dayCellColors(palette, DayAdherence.partial).fill,
      palette.actionSoft,
    );
    expect(dayCellColors(palette, DayAdherence.today).border, palette.action);
    // Colour is repeated by an icon.
    expect(dayCellIcon(DayAdherence.allTaken), Icons.check_rounded);
    expect(dayCellIcon(DayAdherence.partial), Icons.remove_rounded);
    expect(dayCellIcon(DayAdherence.missed), Icons.close_rounded);
    expect(dayCellIcon(DayAdherence.future), isNull);
  });

  test('streak skips empty days and stops at a miss', () {
    final today = LocalDate(2026, 10, 16);
    DayHistory day(int d, DayAdherence adherence) => DayHistory(
          date: LocalDate(2026, 10, d),
          adherence: adherence,
          doses: const [],
          intakes: const [],
        );
    final days = [
      day(12, DayAdherence.missed),
      day(13, DayAdherence.allTaken),
      day(14, DayAdherence.empty),
      day(15, DayAdherence.allTaken),
      day(16, DayAdherence.today),
    ];
    expect(adherenceStreak(days, today), 2);
    expect(adherencePercent(const []), isNull);
  });
}
