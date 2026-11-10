import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/doses/dose_providers.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal/src/features/family/profile_context.dart';
import 'package:pillpal/src/features/stock/stock_level.dart';
import 'package:pillpal/src/features/today/dose_tile.dart';
import 'package:pillpal/src/features/today/today_screen.dart';
import 'package:pillpal/src/features/today/today_state.dart';
import 'package:pillpal/src/features/today/today_widgets.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../helpers.dart';
import '../support/ui_matrix.dart';

// Today in normal mode in the whole UI matrix (docs/ui-pass-plan.md, UI-5a):
// light/dark, normal/senior theme, RU/EN, text scale 1 to 2, two screens.
// The doses are fixed by the test, one per state.

const String _schedule = 'sched-1';

/// The default scales plus the ones where a dose tile may change its layout.
const List<double> _scales = [1.0, 1.15, 1.3, 2.0];

/// A list builds only what is near the viewport: make the screen tall so
/// every dose is built.
const double _tallScreen = 20000;

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

ScheduledDose _dose(String time, DoseStatus status, {DoseMark? mark}) {
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
        _medication('med-low', 'Med L'),
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

/// Records the marks instead of writing them.
class _FakeDoseActions extends DoseActions {
  _FakeDoseActions(super.ref, this.calls);

  final List<String> calls;

  @override
  Future<String?> take(ScheduledDose dose) async {
    calls.add('take ${dose.occurrence.localTime}');
    return 'event';
  }

  @override
  Future<String?> skip(ScheduledDose dose) async {
    calls.add('skip ${dose.occurrence.localTime}');
    return 'event';
  }
}

Widget _screen(
  TestHarness harness, {
  List<String>? calls,
  String? profileId,
  ProfileAccess? access,
}) {
  final state = _state();
  final container = createContainer(
    harness,
    overrides: [
      todayStateProvider.overrideWith((ref, id) => AsyncData(state)),
      doseActionsProvider.overrideWith(
        (ref) => _FakeDoseActions(ref, calls ?? <String>[]),
      ),
      if (access != null)
        profileAccessProvider(profileId).overrideWith(
          (ref) => Stream.value(access),
        ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    // The matrix places the widget at the top start with loose constraints.
    child: SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: TodayScreen(profileId: profileId),
    ),
  );
}

ButtonStyle _style(WidgetTester tester, Finder finder) {
  final widget = tester.widget<ButtonStyleButton>(finder);
  return widget.style!;
}

/// Whether the status of the dose at [time] sits under its name.
bool _stacked(WidgetTester tester, String time) {
  final tile = find.byKey(ValueKey(_key(time)));
  final title = find.descendant(
    of: tile,
    matching: find.text('Med $time 500 mg'),
  );
  final status = find.byKey(ValueKey('dose-take-${_key(time)}'));
  return tester.getTopLeft(status).dy >= tester.getBottomLeft(title).dy - 0.5;
}

/// A known narrow case stacks, a known wide one does not; the progress ring
/// keeps its label inside at any text size.
void _expectLayout(WidgetTester tester, UiMatrixCase cell) {
  final reason = 'tile layout in "${cell.label}"';
  if (cell.scale == 2.0) {
    expect(_stacked(tester, '20:00'), isTrue, reason: reason);
  }
  if (!cell.senior &&
      cell.scale == 1.0 &&
      cell.size.width == 360 &&
      cell.locale.languageCode == 'en') {
    expect(_stacked(tester, '20:00'), isFalse, reason: reason);
  }
  final ring = tester.getRect(find.byType(ProgressRing));
  final label = tester.getRect(
    find.descendant(of: find.byType(ProgressRing), matching: find.byType(Text)),
  );
  expect(ring.contains(label.topLeft), isTrue, reason: reason);
  expect(ring.contains(label.bottomRight), isTrue, reason: reason);
}

void main() {
  testWidgets('Today in the matrix: keys, targets and state colours',
      (tester) async {
    final harness = TestHarness();
    final screen = _screen(harness);
    await pumpUiMatrix(
      tester,
      (context) => screen,
      scales: _scales,
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

        // Pending and snoozed: the action button, as rendered.
        for (final time in ['09:50', '20:00']) {
          final take = find.byKey(ValueKey('dose-take-${_key(time)}'));
          expect(take, findsOneWidget, reason: reason);
          final material = tester.widget<Material>(
            find.descendant(of: take, matching: find.byType(Material)).first,
          );
          expect(material.color, palette.action, reason: reason);
        }

        _expectLayout(tester, cell);

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
        expect(find.byType(DoseTile), findsNWidgets(4), reason: reason);
      },
    );
  });

  testWidgets('the dose sheet keeps its keyed tiles and marks doses',
      (tester) async {
    final harness = TestHarness();
    final calls = <String>[];
    final screen = _screen(harness, calls: calls);
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

        // One cell per mode taps an action: normal takes, senior skips.
        if (cell.brightness == Brightness.light &&
            cell.locale.languageCode == 'en' &&
            cell.scale == 1.0 &&
            cell.size.width == 360) {
          final action = cell.senior ? 'skip' : 'take';
          final before = calls.length;
          await tester.tap(find.byKey(Key('dose-sheet-$action')));
          await tester.pumpAndSettle();
          expect(find.byKey(Key('dose-sheet-$action')), findsNothing,
              reason: reason);
          expect(calls.length, before + 1, reason: reason);
          expect(calls.last, '$action 20:00', reason: reason);
          return;
        }

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

  testWidgets('a relative sees no low-stock notice and no action buttons',
      (tester) async {
    final harness = TestHarness();
    const viewer = ProfileAccess(
      profile: ProfileRow(
        id: 'rel',
        kind: 'self',
        displayName: 'Relative',
        timezone: testZone,
        clientUpdatedAt: 1,
        updatedByDevice: 'd',
        missedAlertMinutes: 30,
        missedAlertsEnabled: true,
      ),
      role: ScopeRole.viewer,
    );
    final screen = _screen(harness, profileId: 'rel', access: viewer);
    await pumpUiMatrix(
      tester,
      (context) => screen,
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        tester.view.physicalSize = Size(cell.size.width, _tallScreen);
        await tester.pump();
        await tester.pump();
        final reason = 'in "${cell.label}"';
        expect(find.byType(DoseTile), findsNWidgets(4), reason: reason);
        expect(find.byType(LowStockBanner), findsNothing, reason: reason);
        expect(
          find.byKey(ValueKey('dose-take-${_key('20:00')}')),
          findsNothing,
          reason: reason,
        );
      },
    );
  });
}
