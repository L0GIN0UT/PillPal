import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/common/status_disc.dart';
import 'package:pillpal/src/features/common/status_kind.dart';
import 'package:pillpal/src/features/doses/dose_providers.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal/src/features/today/senior_groups.dart';
import 'package:pillpal/src/features/today/today_senior.dart';
import 'package:pillpal/src/features/today/today_state.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal/src/theme/radius.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../helpers.dart';
import '../support/ui_matrix.dart';

// Senior Today in the whole UI matrix (docs/redesign-plan.md, R3b): the
// «Сейчас» card at senior sizes in the hero colours of each palette, the
// time groups with a 52 status disc plus a word, 7:1 text and 64 targets. The
// doses are fixed by the test, one per state; two doses share 20:00.

/// The content scrolls as on Today; a tall box builds all of it.
const double _tallContent = 20000;

/// Room for a short screen; it scrolls if the content is higher.
const double _shortContent = 640;

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

TodayState _stateOf(List<ScheduledDose> doses) => TodayState(
      date: LocalDate(2026, 10, 16),
      doses: doses,
      asNeeded: const [],
      lowStock: const [],
      hasMedications: true,
      now: DateTime.utc(2026, 10, 16, 6),
    );

DoseMark _taken() => DoseMark(
      eventId: 'e1',
      type: DoseEventType.taken,
      at: DateTime.utc(2026, 10, 16, 3),
    );

TodayState _state() => _stateOf([
      _dose('a', '07:00', DoseStatus.taken, mark: _taken()),
      // The earliest open dose that is due: the "take now" card.
      _dose('a', '08:00', DoseStatus.missed),
      _dose('b', '08:30', DoseStatus.missed),
      _dose('a', '09:50', DoseStatus.pending),
      _dose('a', '20:00', DoseStatus.pending),
      _dose('b', '20:00', DoseStatus.pending),
    ]);

/// A short screen that fits 360x800 even at senior size: the contrast
/// guideline reads the pixels of the screen only.
TodayState _shortState() => _stateOf([
      _dose('a', '08:00', DoseStatus.pending),
      _dose('b', '20:00', DoseStatus.pending),
    ]);

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

Widget _content(
  TestHarness harness,
  List<String> calls, {
  TodayState? state,
  double height = _tallContent,
}) {
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
      height: height,
      child: SingleChildScrollView(
        child: SeniorTodayContent(state: state ?? _state()),
      ),
    ),
  );
}

Finder _group(String time) => find.byKey(ValueKey('senior-group-$time'));

/// The time sits above the names and the status word below them.
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

/// The status of a group is an icon (the 52 disc) plus a word, and a missed
/// group is the calm iris pair, never red (B2-README section 3).
void _expectGroupStatus(
  WidgetTester tester,
  String time,
  StatusKind kind,
  UiMatrixCase cell,
) {
  final reason = 'in "${cell.label}"';
  final l10n = AppLocalizations.of(tester.element(_group(time)));
  final palette = tester.element(_group(time)).palette;
  final disc = find.descendant(
    of: _group(time),
    matching: find.byType(StatusDisc),
  );
  expect(disc, findsOneWidget, reason: reason);
  expect(tester.widget<StatusDisc>(disc).kind, kind, reason: reason);
  // Normal cells only check that the content lays out; the screen is shown
  // in senior mode alone.
  if (cell.senior) {
    expect(
      tester.getSize(disc),
      const Size.square(PillPalSizes.statusDiscSenior),
      reason: reason,
    );
  }
  final word = tester.widget<Text>(
    find.byKey(ValueKey('senior-group-status-$time')),
  );
  expect(word.data, statusWord(l10n, kind), reason: reason);
  if (kind == StatusKind.missed) {
    expect(word.style?.color, isNot(palette.danger), reason: reason);
  }
}

/// The «Сейчас» card at senior sizes, in the hero colours of the palette.
void _expectSeniorHero(WidgetTester tester, UiMatrixCase cell) {
  final reason = 'in "${cell.label}"';
  final now = find.byKey(const Key('senior-now'));
  final palette = tester.element(now).palette;
  final card = tester.widget<Material>(
    find.descendant(of: now, matching: find.byType(Material)).first,
  );
  expect(card.color, palette.hero, reason: reason);
  expect(
    (card.shape! as RoundedRectangleBorder).borderRadius,
    PillPalRadius.hero,
    reason: reason,
  );

  final take = find.byKey(ValueKey('dose-take-${_key('a', '08:00')}'));
  final style = tester.widget<FilledButton>(take).style!;
  expect(style.backgroundColor!.resolve({}), palette.heroAction,
      reason: reason);
  expect(style.foregroundColor!.resolve({}), palette.onHeroAction,
      reason: reason);
  if (!cell.senior) {
    return;
  }
  // Senior sizes: «Принял» 76 with a 26 label, snooze and skip 64.
  expect(
    tester.getSize(take).height,
    greaterThanOrEqualTo(PillPalSizes.seniorTakeHeight),
    reason: reason,
  );
  expect(style.textStyle!.resolve({})!.fontSize, heroTakeSeniorSize,
      reason: reason);
  for (final key in ['senior-skip', 'senior-snooze']) {
    expect(
      tester.getSize(find.byKey(Key(key))).height,
      greaterThanOrEqualTo(PillPalSizes.seniorButtonHeight),
      reason: '$key $reason',
    );
  }
}

void main() {
  test('the status of a group: taken, missed first, skipped, waiting', () {
    StatusKind of(List<DoseStatus> statuses) => groupStatusKind([
          for (final (i, status) in statuses.indexed)
            _dose('a', '0$i:00', status),
        ]);

    expect(of([DoseStatus.taken, DoseStatus.taken]), StatusKind.taken);
    expect(of([DoseStatus.taken, DoseStatus.missed]), StatusKind.missed);
    expect(of([DoseStatus.pending, DoseStatus.missed]), StatusKind.missed);
    expect(of([DoseStatus.skipped, DoseStatus.skipped]), StatusKind.skipped);
    expect(of([DoseStatus.taken, DoseStatus.skipped]), StatusKind.pending);
    expect(of([DoseStatus.taken, DoseStatus.pending]), StatusKind.pending);
  });

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
        _expectSeniorHero(tester, cell);
        for (final (time, kind) in [
          ('07:00', StatusKind.taken),
          ('08:30', StatusKind.missed),
          ('09:50', StatusKind.pending),
          ('20:00', StatusKind.pending),
        ]) {
          _expectStacked(tester, time, reason);
          _expectGroupStatus(tester, time, kind, cell);
        }
        // The "now" dose has no group of its own.
        expect(_group('08:00'), findsNothing, reason: reason);
      },
    );
  });

  testWidgets('senior Today meets 7:1 text contrast', (tester) async {
    final harness = TestHarness();
    final screen = _content(
      harness,
      <String>[],
      state: _shortState(),
      height: _shortContent,
    );
    await pumpUiMatrix(
      tester,
      (context) => screen,
      expectContrast: true,
      scales: const [1.0],
      sizes: const [uiContrastSize],
    );
  });

  testWidgets('all taken: the calm banner, readable and keyed', (tester) async {
    final harness = TestHarness();
    final screen = _content(
      harness,
      <String>[],
      state: _stateOf([
        _dose('a', '08:00', DoseStatus.taken, mark: _taken()),
      ]),
      height: _shortContent,
    );
    await pumpUiMatrix(
      tester,
      (context) => screen,
      expectTouchTargets: true,
      expectContrast: true,
      check: (tester, cell) async {
        expect(
          find.byKey(const Key('today-all-taken')),
          findsOneWidget,
          reason: 'in "${cell.label}"',
        );
        expect(find.byKey(const Key('senior-now')), findsNothing);
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
