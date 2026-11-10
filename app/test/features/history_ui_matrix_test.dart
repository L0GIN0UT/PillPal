import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/common/choice_group.dart';
import 'package:pillpal/src/features/common/sheet_scaffold.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal/src/features/history/history_model.dart';
import 'package:pillpal/src/features/history/history_providers.dart';
import 'package:pillpal/src/features/history/history_screen.dart';
import 'package:pillpal/src/features/history/month_calendar.dart';
import 'package:pillpal/src/features/report/report_sheet.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../helpers.dart';
import '../support/ui_matrix.dart';

// History and the report sheet in the whole UI matrix (docs/ui-pass-plan.md,
// UI-8). The month is fixed by the test: one day of every colour class.

/// A list builds only what is near the viewport: make the screen tall.
const double _tallScreen = 4000;

MedicationRow _medication() => const MedicationRow(
      id: 'med-1',
      profileId: 'self',
      name: 'Med H',
      strengthText: '500 mg',
      tzMode: 'local',
      privacy: 'shared',
      redacted: false,
      gtinLinkShared: false,
      clientUpdatedAt: 1,
      updatedByDevice: 'd',
    );

ScheduledDose _dose(int day, String time, DoseStatus status) {
  final hour = int.parse(time.substring(0, 2));
  return ScheduledDose(
    medication: _medication(),
    scheduleId: 'sched-1',
    occurrence: Occurrence(
      key: 'sched-1/2026-10-${day.toString().padLeft(2, '0')}T$time',
      localDate: LocalDate(2026, 10, day),
      localTime: time,
      atUtc: DateTime.utc(2026, 10, day, hour - 4),
      doseAmount: '1',
      doseUnit: 'tablet',
    ),
    status: status,
    mark: null,
    zone: testZone,
    displayZone: testZone,
  );
}

/// October 2026: the 1st all taken, the 2nd partial, the 3rd missed, the 4th
/// empty, the 16th today, the rest in the future.
MonthHistory _month() {
  DayAdherence adherenceOf(int day) {
    if (day == 1) return DayAdherence.allTaken;
    if (day == 2) return DayAdherence.partial;
    if (day == 3) return DayAdherence.missed;
    if (day < 16) return DayAdherence.empty;
    return day == 16 ? DayAdherence.today : DayAdherence.future;
  }

  List<ScheduledDose> dosesOf(int day) => switch (day) {
        1 => [_dose(1, '08:00', DoseStatus.taken)],
        2 => [
            _dose(2, '08:00', DoseStatus.taken),
            _dose(2, '20:00', DoseStatus.missed),
          ],
        3 => [_dose(3, '08:00', DoseStatus.missed)],
        _ => const [],
      };

  return MonthHistory(
    month: LocalDate(2026, 10, 1),
    days: [
      for (var day = 1; day <= 31; day++)
        DayHistory(
          date: LocalDate(2026, 10, day),
          adherence: adherenceOf(day),
          doses: dosesOf(day),
          intakes: const [],
        ),
    ],
    adherencePercent: 67,
  );
}

Widget _screen(TestHarness harness) {
  final container = createContainer(
    harness,
    overrides: [
      monthHistoryProvider(null).overrideWithValue(AsyncData(_month())),
      adherenceStreakProvider(null).overrideWithValue(const AsyncData(3)),
      historyZoneProvider(null).overrideWithValue(testZone),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: const SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: HistoryScreen(),
    ),
  );
}

Color? _fillOf(WidgetTester tester, String date) {
  final cell = find.byKey(ValueKey('day-$date'));
  return tester
      .widget<Material>(
        find.descendant(of: cell, matching: find.byType(Material)).first,
      )
      .color;
}

final Finder _cells = find.byType(CalendarDayCell);

/// One sage scale: taken, soft sage for some taken, blue for misses.
void _expectSageScale(WidgetTester tester, String reason) {
  final palette = tester.element(find.byType(HistoryScreen)).palette;
  expect(_fillOf(tester, '2026-10-01'), palette.taken, reason: reason);
  expect(_fillOf(tester, '2026-10-02'), palette.takenSoft, reason: reason);
  expect(_fillOf(tester, '2026-10-03'), palette.missed, reason: reason);
}

/// The legend is centred, its markers are round and grow in senior mode.
void _expectLegend(WidgetTester tester, UiMatrixCase cell, String reason) {
  final legend = find.byKey(const Key('history-legend'));
  expect(legend, findsOneWidget, reason: reason);
  expect(
    tester.widget<Wrap>(legend).alignment,
    WrapAlignment.center,
    reason: reason,
  );
  final markers = find.descendant(
    of: legend,
    matching: find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).shape == BoxShape.circle,
    ),
  );
  expect(markers, findsNWidgets(3), reason: reason);
  expect(
    tester.getSize(markers.first).width,
    cell.senior ? PillPalSizes.legendMarkerSenior : PillPalSizes.legendMarker,
    reason: reason,
  );
}

void _expectKeys(List<String> keys, String reason) {
  for (final key in keys) {
    expect(
      find.byKey(Key(key)),
      findsOneWidget,
      reason: '"$key" is missing $reason',
    );
  }
}

void _expectTargets(WidgetTester tester, UiMatrixCase cell) =>
    expectTouchTargetsOf(tester, cell, heightOnlyWithin: _cells);

/// A tap opens the details of a day and a second tap closes them (the
/// selection lives in the shared container).
Future<void> _expectDayDetails(
  WidgetTester tester,
  UiMatrixCase cell,
  String reason,
) async {
  final day = find.byKey(const ValueKey('day-2026-10-02'));
  await tester.tap(day);
  await tester.pump();
  expect(find.byKey(const Key('history-day')), findsOneWidget, reason: reason);
  _expectTargets(tester, cell);
  await tester.tap(day);
  await tester.pump();
  expect(find.byKey(const Key('history-day')), findsNothing, reason: reason);
}

/// Today selected keeps its action ring inside the ink selection border.
Future<void> _expectTodayRing(WidgetTester tester, String reason) async {
  final palette = tester.element(find.byType(HistoryScreen)).palette;
  final today = find.byKey(const ValueKey('day-2026-10-16'));
  BorderSide outer() => ((tester
          .widget<Material>(
            find.descendant(of: today, matching: find.byType(Material)).first,
          )
          .shape!) as RoundedRectangleBorder)
      .side;
  expect(outer().color, palette.action, reason: reason);
  await tester.tap(today);
  await tester.pump();
  expect(outer().color, palette.ink, reason: reason);
  final inner = find.descendant(
    of: today,
    matching: find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).border?.top.color == palette.action,
    ),
  );
  expect(inner, findsOneWidget, reason: reason);
  await tester.tap(today);
  await tester.pump();
}

/// The shared sheet and choice group, keys and targets of the report sheet.
void _expectReportSheet(WidgetTester tester, UiMatrixCase cell, String r) {
  expect(find.byType(SheetScaffold), findsOneWidget, reason: r);
  expect(find.byType(ChoiceGroup<int?>), findsOneWidget, reason: r);
  _expectKeys([
    'report-days-7',
    'report-days-30',
    'report-days-90',
    'report-custom',
    'report-range',
    'report-share',
  ], r);
  expectTouchTargetsOf(tester, cell);
}

/// A preset keeps the sheet; "custom" opens the range picker (the
/// framework's own dialog is not laid out for large text or a small screen).
Future<void> _useReportChoices(
  WidgetTester tester,
  UiMatrixCase cell,
  String reason,
) async {
  await tester.ensureVisible(find.byKey(const Key('report-days-7')));
  await tester.tap(find.byKey(const Key('report-days-7')));
  await tester.pump();
  if (!cell.senior && cell.scale == 1.0 && cell.size.width == 360) {
    await tester.ensureVisible(find.byKey(const Key('report-custom')));
    await tester.tap(find.byKey(const Key('report-custom')));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsOneWidget, reason: reason);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsNothing, reason: reason);
  }
  expect(find.byKey(const Key('report-share')), findsOneWidget, reason: reason);
}

void main() {
  testWidgets('History in the matrix: sage scale, legend, keys and targets',
      (tester) async {
    final screen = _screen(TestHarness());
    await pumpUiMatrix(
      tester,
      (context) => screen,
      expectTouchTargets: true,
      // Seven cells share the width: the height is the target.
      heightOnlyWithin: _cells,
      check: (tester, cell) async {
        tester.view.physicalSize = Size(cell.size.width, _tallScreen);
        await tester.pump();
        final reason = 'in "${cell.label}"';
        _expectTargets(tester, cell);
        _expectSageScale(tester, reason);
        _expectLegend(tester, cell, reason);
        _expectKeys([
          'history-percent',
          'history-streak',
          'history-month',
          'history-previous',
          'history-next',
          'history-pdf',
        ], reason);
        await _expectDayDetails(tester, cell, reason);
        await _expectTodayRing(tester, reason);
      },
    );
  });

  testWidgets('the report sheet in the matrix: choices, custom and targets',
      (tester) async {
    final container = createContainer(TestHarness());
    await pumpUiMatrix(
      tester,
      (context) => FilledButton(
        key: const Key('open'),
        onPressed: () => showReportSheet(context),
        child: const Text('open'),
      ),
      wrap: (app) =>
          UncontrolledProviderScope(container: container, child: app),
      check: (tester, cell) async {
        final reason = 'in "${cell.label}"';
        await tester.tap(find.byKey(const Key('open')));
        await tester.pumpAndSettle();
        _expectReportSheet(tester, cell, reason);
        await _useReportChoices(tester, cell, reason);
      },
    );
  });
}
