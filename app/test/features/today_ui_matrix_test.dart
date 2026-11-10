import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal/src/features/stock/stock_level.dart';
import 'package:pillpal/src/features/today/dose_tile.dart';
import 'package:pillpal/src/features/today/today_screen.dart';
import 'package:pillpal/src/features/today/today_state.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../helpers.dart';
import '../support/ui_matrix.dart';

// Today in normal mode in the whole UI matrix (docs/ui-pass-plan.md, UI-5a):
// light/dark, normal/senior theme, RU/EN, text scale 1 and 2, two screens.
// The doses are fixed by the test, one per state.

const String _schedule = 'sched-1';

MedicationRow _medication(String id, String name) => MedicationRow(
      id: id,
      profileId: 'self',
      name: name,
      strengthText: '500 mg',
      tzMode: 'local',
      privacy: 'shared',
      redacted: false,
      gtinLinkShared: false,
      clientUpdatedAt: 1,
      updatedByDevice: 'd',
    );

String _key(String time) => '$_schedule/2026-10-16T$time';

ScheduledDose _dose(
  String time,
  DoseStatus status, {
  DoseMark? mark,
}) {
  final hour = int.parse(time.substring(0, 2));
  return ScheduledDose(
    medication: _medication('med-$time', 'Med $time'),
    scheduleId: _schedule,
    occurrence: Occurrence(
      key: _key(time),
      localDate: LocalDate(2026, 10, 16),
      localTime: time,
      atUtc: DateTime.utc(2026, 10, 16, hour - 4),
      doseAmount: '1',
      doseUnit: 'tablet',
    ),
    status: status,
    mark: mark,
    zone: testZone,
    displayZone: testZone,
  );
}

TodayState _state() {
  final taken = DoseMark(
    eventId: 'e1',
    type: DoseEventType.taken,
    at: DateTime.utc(2026, 10, 16, 3),
  );
  final low = _medication('med-low', 'Med L');
  return TodayState(
    date: LocalDate(2026, 10, 16),
    doses: [
      _dose('07:00', DoseStatus.taken, mark: taken),
      _dose('08:00', DoseStatus.missed),
      // Snoozed: not marked and not yet overdue, so still pending.
      _dose('09:50', DoseStatus.pending),
      _dose('20:00', DoseStatus.pending),
    ],
    asNeeded: const [],
    lowStock: [
      LowStockMedication(
        low,
        const StockKnown(
          remainingMilli: 2000,
          unit: DoseUnit.tablet,
          daysLeft: 2,
        ),
      ),
    ],
    hasMedications: true,
    now: DateTime.utc(2026, 10, 16, 6),
  );
}

Widget _screen(TestHarness harness) {
  final state = _state();
  final container = createContainer(
    harness,
    overrides: [
      todayStateProvider.overrideWith((ref, id) => AsyncData(state)),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    // The matrix places the widget at the top start with loose constraints.
    child: const SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: TodayScreen(),
    ),
  );
}

/// A list builds only what is near the viewport: make the screen tall so
/// every dose is built.
const double _tallScreen = 20000;

ButtonStyle _style(WidgetTester tester, Finder finder) {
  final widget = tester.widget<ButtonStyleButton>(finder);
  return widget.style!;
}

void main() {
  testWidgets('Today in the matrix: keys, targets and state colours',
      (tester) async {
    final harness = TestHarness();
    final screen = _screen(harness);
    await pumpUiMatrix(
      tester,
      (context) => screen,
      expectTouchTargets: true,
      check: (tester, cell) async {
        tester.view.physicalSize = Size(cell.size.width, _tallScreen);
        await tester.pump();
        expectTouchTargetsOf(tester, cell);

        final palette = tester.element(find.byType(TodayScreen)).palette;
        final reason = 'in "${cell.label}"';

        // Taken: a badge in the taken colour with its "on" colour.
        final takenBadge = find.byKey(ValueKey('dose-taken-${_key('07:00')}'));
        expect(takenBadge, findsOneWidget, reason: reason);
        final badge = tester.widget<Container>(
          find.descendant(of: takenBadge, matching: find.byType(Container)),
        );
        expect(
          (badge.decoration! as BoxDecoration).color,
          palette.taken,
          reason: reason,
        );
        expect(
          tester
              .widget<Icon>(
                find.descendant(of: takenBadge, matching: find.byType(Icon)),
              )
              .color,
          palette.onTaken,
          reason: reason,
        );

        // Missed: an outlined button in the missed colour.
        final missed = find.byKey(ValueKey('dose-missed-${_key('08:00')}'));
        expect(missed, findsOneWidget, reason: reason);
        final missedStyle = _style(tester, missed);
        expect(
          missedStyle.foregroundColor!.resolve({}),
          palette.missed,
          reason: reason,
        );
        expect(
          missedStyle.side!.resolve({})!.color,
          palette.missed,
          reason: reason,
        );

        // Pending and snoozed: the action button.
        for (final time in ['09:50', '20:00']) {
          final take = find.byKey(ValueKey('dose-take-${_key(time)}'));
          expect(take, findsOneWidget, reason: reason);
          final theme = Theme.of(tester.element(take));
          expect(
            theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
            palette.action,
            reason: reason,
          );
        }

        for (final key in [
          'today-title',
          'today-summary',
          'today-add',
          'low-stock-med-low',
          'low-stock-pharmacies-med-low',
          'low-stock-refill-med-low',
        ]) {
          expect(
            find.byKey(Key(key)),
            findsOneWidget,
            reason: '"$key" is missing $reason',
          );
        }
        expect(
          find.byType(DoseTile),
          findsNWidgets(4),
          reason: reason,
        );
      },
    );
  });

  testWidgets('the dose sheet keeps its keyed tiles in the matrix',
      (tester) async {
    final harness = TestHarness();
    final screen = _screen(harness);
    await pumpUiMatrix(
      tester,
      (context) => screen,
      check: (tester, cell) async {
        tester.view.physicalSize = Size(cell.size.width, _tallScreen);
        await tester.pump();
        await tester.tap(find.byKey(ValueKey(_key('20:00'))));
        await tester.pumpAndSettle();
        final reason = 'in "${cell.label}"';
        expect(find.byKey(const Key('dose-sheet-take')), findsOneWidget,
            reason: reason);
        expect(find.byKey(const Key('dose-sheet-skip')), findsOneWidget,
            reason: reason);
        expect(find.byKey(const Key('dose-sheet-undo')), findsNothing,
            reason: reason);
        expectTouchTargetsOf(tester, cell);

        // The taken dose offers an undo instead.
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey(_key('07:00'))));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('dose-sheet-undo')), findsOneWidget,
            reason: reason);
        expect(find.byKey(const Key('dose-sheet-take')), findsNothing,
            reason: reason);
      },
    );
  });
}
