import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/doses/dose_providers.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal/src/features/today/today_senior.dart';
import 'package:pillpal/src/features/today/today_state.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal/src/theme/radius.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../helpers.dart';
import '../support/ui_matrix.dart';

// Senior Today in the whole UI matrix (docs/ui-pass-plan.md, UI-5b): the
// "take now" card, the time groups and the group sheet. The doses are fixed
// by the test, one per state; two doses share 20:00.

/// The content scrolls as on Today; a tall box builds all of it.
const double _tallContent = 20000;

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

String _key(String schedule, String time) => '$schedule/2026-10-16T$time';

ScheduledDose _dose(
  String schedule,
  String time,
  DoseStatus status, {
  DoseMark? mark,
}) {
  final hour = int.parse(time.substring(0, 2));
  return ScheduledDose(
    medication: _medication('med-$schedule', 'Med $schedule'),
    scheduleId: schedule,
    occurrence: Occurrence(
      key: _key(schedule, time),
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
  return TodayState(
    date: LocalDate(2026, 10, 16),
    doses: [
      _dose('a', '07:00', DoseStatus.taken, mark: taken),
      // The earliest open dose that is due: the "take now" card.
      _dose('a', '08:00', DoseStatus.missed),
      _dose('a', '09:50', DoseStatus.pending),
      _dose('a', '20:00', DoseStatus.pending),
      _dose('b', '20:00', DoseStatus.pending),
    ],
    asNeeded: const [],
    lowStock: const [],
    hasMedications: true,
    now: DateTime.utc(2026, 10, 16, 6),
  );
}

/// Records the marks instead of writing them.
class _FakeDoseActions extends DoseActions {
  _FakeDoseActions(super.ref, this.calls);

  final List<String> calls;

  @override
  Future<String?> take(ScheduledDose dose) async {
    calls.add('take ${dose.occurrence.key}');
    return 'event';
  }
}

Widget _content(TestHarness harness, List<String> calls) {
  final container = createContainer(
    harness,
    overrides: [
      doseActionsProvider.overrideWith((ref) => _FakeDoseActions(ref, calls)),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: SizedBox(
      width: double.infinity,
      height: _tallContent,
      child: SingleChildScrollView(
        child: SeniorTodayContent(state: _state()),
      ),
    ),
  );
}

Finder _group(String time) => find.byKey(ValueKey('senior-group-$time'));

/// The time sits above the names and the status below them (the stacked
/// arrangement of a normal dose tile).
void _expectStacked(WidgetTester tester, String time, String reason) {
  final timeText = find.descendant(of: _group(time), matching: find.text(time));
  final status = find.byKey(ValueKey('senior-group-status-$time'));
  final names = find.byKey(ValueKey('senior-group-names-$time'));
  expect(timeText, findsOneWidget, reason: reason);
  expect(status, findsOneWidget, reason: reason);
  expect(names, findsOneWidget, reason: reason);
  expect(
    tester.getBottomLeft(timeText).dy,
    lessThanOrEqualTo(tester.getTopLeft(names).dy + 0.5),
    reason: 'time above names, $reason',
  );
  expect(
    tester.getTopLeft(status).dy,
    greaterThanOrEqualTo(tester.getBottomLeft(names).dy - 0.5),
    reason: 'status below names, $reason',
  );
}

void main() {
  testWidgets('senior Today in the matrix: card, groups, keys and targets',
      (tester) async {
    final harness = TestHarness();
    final screen = _content(harness, <String>[]);
    await pumpUiMatrix(
      tester,
      (context) => screen,
      expectTouchTargets: true,
      check: (tester, cell) async {
        final reason = 'in "${cell.label}"';
        final now = find.byKey(const Key('senior-now'));
        final palette = tester.element(now).palette;

        // The "take now" card: radius 24, a 2 px outline in the action colour.
        final card = tester.widget<Container>(now);
        final decoration = card.decoration! as BoxDecoration;
        expect(decoration.borderRadius, PillPalRadius.hero, reason: reason);
        final border = decoration.border! as Border;
        expect(border.top.color, palette.action, reason: reason);
        expect(border.top.width, PillPalSizes.outline, reason: reason);

        // A big "Taken" button, never below the target of the mode.
        final take = find.byKey(ValueKey('dose-take-${_key('a', '08:00')}'));
        expect(
          tester.getSize(take).height,
          greaterThanOrEqualTo(cell.touchTarget),
          reason: reason,
        );
        expect(find.byKey(const Key('senior-skip')), findsOneWidget);
        expect(find.byKey(const Key('senior-snooze')), findsOneWidget);

        // Groups: radius 24 surface cards, stacked.
        for (final time in ['07:00', '09:50', '20:00']) {
          final material = tester.widget<Material>(_group(time));
          expect(material.color, palette.surface, reason: reason);
          expect(material.borderRadius, PillPalRadius.hero, reason: reason);
          _expectStacked(tester, time, reason);
        }
        // The "now" dose has no group of its own.
        expect(_group('08:00'), findsNothing, reason: reason);
      },
    );
  });

  testWidgets('a group of two doses opens a sheet of keyed, large rows',
      (tester) async {
    final harness = TestHarness();
    final calls = <String>[];
    final screen = _content(harness, calls);
    await pumpUiMatrix(
      tester,
      (context) => screen,
      scales: const [1.0],
      check: (tester, cell) async {
        final reason = 'in "${cell.label}"';
        await tester.ensureVisible(_group('20:00'));
        await tester.tap(_group('20:00'));
        await tester.pumpAndSettle();
        for (final schedule in ['a', 'b']) {
          expect(
            find.byKey(
              ValueKey('senior-group-dose-${_key(schedule, '20:00')}'),
            ),
            findsOneWidget,
            reason: reason,
          );
        }
        expectTouchTargetsOf(tester, cell);

        await tester.tap(
          find.byKey(ValueKey('senior-group-dose-${_key('b', '20:00')}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('dose-sheet-take')));
        await tester.pumpAndSettle();
        expect(calls.last, 'take ${_key('b', '20:00')}', reason: reason);
      },
    );
  });
}
