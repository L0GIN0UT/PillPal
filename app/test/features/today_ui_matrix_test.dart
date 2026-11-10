import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/common/round_check_button.dart';
import 'package:pillpal/src/features/common/status_disc.dart';
import 'package:pillpal/src/features/family/profile_context.dart';
import 'package:pillpal/src/features/today/dose_tile.dart';
import 'package:pillpal/src/features/today/today_screen.dart';
import 'package:pillpal/src/features/today/today_widgets.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal/src/theme/sizes.dart';

import '../helpers.dart';
import '../support/today_fixtures.dart';
import '../support/ui_matrix.dart';

// Today in normal mode in the whole UI matrix (docs/redesign-plan.md, R3a):
// light/dark, normal/senior theme, RU/EN, text scales and two screens. The
// doses are fixed by the test, one per state.

/// The default scales plus x1.3, where senior cells cross the x1.6 line.
const List<double> _scales = [1.0, 1.3, 2.0];

/// A list builds only what is near the viewport: make the screen tall so
/// every dose is built.
const double _tallScreen = 20000;

String _key(String time) => fixtureKey(time);

ButtonStyle _style(WidgetTester tester, Finder finder) =>
    tester.widget<ButtonStyleButton>(finder).style!;

/// The colour of the text the widget with [key] is.
Color? _textColor(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).style?.color;

/// Whether the header puts its actions on their own line (x1.6 and up).
bool _compact(WidgetTester tester) =>
    MediaQuery.textScalerOf(tester.element(find.byType(TodayScreen)))
        .scale(1) >=
    PillPalSizes.compactRowScale;

/// The looks of the doses: the «Сейчас» card, the quick-take check, the
/// «Уже было» rows, never red for a missed one.
void _expectDoseLooks(WidgetTester tester, PillPalPalette palette, String at) {
  // Taken: a disc and a status line in the soft taken colours.
  final takenKey = ValueKey('dose-taken-${_key('07:00')}');
  expect(find.byKey(takenKey), findsOneWidget, reason: at);
  expect(_textColor(tester, takenKey), palette.onTakenSoft, reason: at);
  expect(
    find.descendant(
      of: find.byKey(ValueKey(_key('07:00'))),
      matching: find.byType(StatusDisc),
    ),
    findsOneWidget,
    reason: at,
  );

  // Missed: calm iris, never danger.
  final missedKey = ValueKey('dose-missed-${_key('08:00')}');
  expect(find.byKey(missedKey), findsOneWidget, reason: at);
  expect(_textColor(tester, missedKey), palette.onMissedSoft, reason: at);
  expect(_textColor(tester, missedKey), isNot(palette.danger), reason: at);

  // The dose to take now is the hero: «Принял» in the hero action colours.
  final take = find.byKey(ValueKey('dose-take-${_key('09:50')}'));
  expect(take, findsOneWidget, reason: at);
  final style = _style(tester, take);
  expect(style.backgroundColor!.resolve({}), palette.heroAction, reason: at);
  expect(style.foregroundColor!.resolve({}), palette.onHeroAction, reason: at);
  expect(
    find.byKey(ValueKey('dose-snooze-${_key('09:50')}')),
    findsOneWidget,
    reason: at,
  );

  // The later dose has the round check.
  expect(
    tester.widget(find.byKey(ValueKey('dose-take-${_key('20:00')}'))),
    isA<RoundCheckButton>(),
    reason: at,
  );
}

/// Ring or counter, and the header actions: both follow the effective text
/// scale (section 9.3 and 9.4 of the B2 README).
void _expectHeader(WidgetTester tester, String at) {
  final summary = find.byKey(const Key('today-summary'));
  expect(summary, findsOneWidget, reason: at);
  final title = find.byKey(const Key('today-title'));
  final add = find.byKey(const Key('today-add'));
  if (_compact(tester)) {
    expect(tester.widget(summary), isA<Text>(), reason: '$at: counter text');
    expect(find.byType(ProgressRing), findsNothing, reason: at);
    expect(
      tester.getTopLeft(add).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(title).dy - 0.5),
      reason: '$at: actions on their own line',
    );
  } else {
    expect(tester.widget(summary), isA<ProgressRing>(), reason: at);
    expect(
      tester.getBottomLeft(add).dy,
      lessThanOrEqualTo(tester.getTopLeft(title).dy + 0.5),
      reason: '$at: actions beside the date',
    );
  }
}

void main() {
  testWidgets('Today in the matrix: keys, targets, contrast and looks',
      (tester) async {
    final harness = TestHarness();
    final screen = fixtureTodayScreen(harness);
    await pumpUiMatrix(
      tester,
      (context) => screen,
      scales: _scales,
      expectTouchTargets: true,
      expectContrast: true,
      check: (tester, cell) async {
        tester.view.physicalSize = Size(cell.size.width, _tallScreen);
        await tester.pump();
        expectTouchTargetsOf(tester, cell);

        final palette = tester.element(find.byType(TodayScreen)).palette;
        final reason = 'in "${cell.label}"';
        _expectDoseLooks(tester, palette, reason);
        _expectHeader(tester, reason);

        for (final key in [
          'today-title',
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
        // Exactly one tile per dose; the hero is one of them.
        expect(find.byType(DoseTile), findsNWidgets(4), reason: reason);
        expect(
          find.byKey(ValueKey(_key('09:50'))),
          findsOneWidget,
          reason: reason,
        );
      },
    );
  });

  testWidgets('the dose sheet keeps its keyed tiles and marks doses',
      (tester) async {
    final harness = TestHarness();
    final calls = <String>[];
    final screen = fixtureTodayScreen(harness, calls: calls);
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

  testWidgets('a relative sees no low-stock notice, hero or action buttons',
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
    final screen =
        fixtureTodayScreen(harness, profileId: 'rel', access: viewer);
    await pumpUiMatrix(
      tester,
      (context) => screen,
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      expectTouchTargets: true,
      check: (tester, cell) async {
        tester.view.physicalSize = Size(cell.size.width, _tallScreen);
        await tester.pump();
        await tester.pump();
        final reason = 'in "${cell.label}"';
        expect(find.byType(DoseTile), findsNWidgets(4), reason: reason);
        expect(find.byType(LowStockBanner), findsNothing, reason: reason);
        expect(
          find.byWidgetPredicate((widget) {
            final key = widget.key;
            return key is ValueKey<String> &&
                (key.value.startsWith('dose-take-') ||
                    key.value.startsWith('dose-snooze-'));
          }),
          findsNothing,
          reason: reason,
        );
        // Every dose shows its status by icon and word.
        for (final time in ['07:00', '08:00', '09:50', '20:00']) {
          expect(
            find.byKey(ValueKey('dose-status-${_key(time)}')),
            findsOneWidget,
            reason: '$time $reason',
          );
        }
      },
    );
  });
}
