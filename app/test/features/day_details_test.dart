import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/common/status_kind.dart';
import 'package:pillpal/src/features/common/status_pill.dart';
import 'package:pillpal/src/features/doses/day_part.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal/src/features/history/day_details.dart';
import 'package:pillpal/src/features/history/history_model.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../helpers.dart';
import '../support/ui_matrix.dart';

// The day behind a calendar cell (B2-HistoryDay): groups by time of day, a
// status pill (icon and word) per entry, "Taken at ..." when marked.

MedicationRow _medication({bool redacted = false}) => MedicationRow(
      id: 'med-1',
      profileId: 'self',
      name: redacted ? null : 'Med D',
      strengthText: redacted ? null : '500 mg',
      tzMode: 'local',
      privacy: redacted ? 'anonymous' : 'shared',
      redacted: redacted,
      gtinLinkShared: false,
      clientUpdatedAt: 1,
      updatedByDevice: 'd',
    );

ScheduledDose _dose(
  String time,
  DoseStatus status, {
  DateTime? markedAt,
  bool redacted = false,
}) {
  final hour = int.parse(time.substring(0, 2));
  return ScheduledDose(
    medication: _medication(redacted: redacted),
    scheduleId: 'sched-1',
    occurrence: Occurrence(
      key: 'sched-1/2026-10-02T$time',
      localDate: LocalDate(2026, 10, 2),
      localTime: time,
      atUtc: DateTime.utc(2026, 10, 2, hour - 4),
      doseAmount: '1',
      doseUnit: 'tablet',
    ),
    status: status,
    mark: markedAt == null
        ? null
        : DoseMark(eventId: 'e-$time', type: DoseEventType.taken, at: markedAt),
    zone: testZone,
    displayZone: testZone,
  );
}

DayHistory _day(List<ScheduledDose> doses, {List<DoseEventRow>? intakes}) =>
    DayHistory(
      date: LocalDate(2026, 10, 2),
      adherence: DayAdherence.partial,
      doses: doses,
      intakes: intakes ?? const [],
    );

/// As on the screen: inside a list, so a tall day scrolls instead of
/// overflowing the test's box.
Widget _scrolled(Widget child) => SizedBox(
      width: double.infinity,
      height: _screenHeight,
      child: SingleChildScrollView(child: child),
    );

const double _screenHeight = 2000;

/// The background of the pill that holds [word].
Color? _pillFill(WidgetTester tester, Finder pill) {
  final decorated = find.descendant(
    of: pill,
    matching: find.byWidgetPredicate(
      (w) => w is DecoratedBox && w.decoration is ShapeDecoration,
    ),
  );
  return (tester.widget<DecoratedBox>(decorated.first).decoration
          as ShapeDecoration)
      .color;
}

void main() {
  test('the part of the day changes at 12:00 and 18:00', () {
    expect(dayPartOf('00:00'), DayPart.morning);
    expect(dayPartOf('11:59'), DayPart.morning);
    expect(dayPartOf('12:00'), DayPart.day);
    expect(dayPartOf('17:59'), DayPart.day);
    expect(dayPartOf('18:00'), DayPart.evening);
    expect(dayPartOf('23:59'), DayPart.evening);
  });

  testWidgets('groups, pills, marks and a miss that is not red',
      (tester) async {
    final doses = [
      _dose('20:00', DoseStatus.missed),
      // 08:04 in UTC+4.
      _dose('08:00', DoseStatus.taken,
          markedAt: DateTime.utc(2026, 10, 2, 4, 4)),
      _dose('14:00', DoseStatus.skipped),
    ];
    await pumpUiMatrix(
      tester,
      (context) => _scrolled(DayDetails(day: _day(doses), zone: testZone)),
      expectTouchTargets: true,
      check: (tester, cell) async {
        final reason = 'in "${cell.label}"';
        // Tall, so the contrast of every pixel is on screen.
        tester.view.physicalSize = Size(cell.size.width, _screenHeight);
        await tester.pump();
        if (cell.scale == uiContrastScale && cell.size == uiContrastSize) {
          await expectContrastOf(tester, cell);
        }
        final palette = tester.element(find.byType(DayDetails)).palette;
        for (final part in ['morning', 'day', 'evening']) {
          expect(find.byKey(Key('day-part-$part')), findsOneWidget,
              reason: reason);
        }
        // Entries in time order, whatever the order they came in.
        final times = tester.widgetList<Text>(find.byType(Text)).map(
              (t) => t.data,
            );
        expect(
          times.where((t) => const {'08:00', '14:00', '20:00'}.contains(t)),
          ['08:00', '14:00', '20:00'],
          reason: reason,
        );
        // Status = icon + word, in the pill of the kind.
        final kinds = tester
            .widgetList<StatusPill>(find.byType(StatusPill))
            .map((pill) => pill.kind);
        expect(
          kinds,
          [
            StatusKind.taken, // summary
            StatusKind.missed, // summary
            StatusKind.taken,
            StatusKind.skipped,
            StatusKind.missed,
          ],
          reason: reason,
        );
        final missed = find.byWidgetPredicate(
          (w) => w is StatusPill && w.kind == StatusKind.missed,
        );
        expect(
          find.descendant(
              of: missed.last, matching: find.byIcon(Icons.history)),
          findsOneWidget,
          reason: reason,
        );
        final fill = _pillFill(tester, missed.last);
        expect(fill, palette.missedSoft, reason: reason);
        expect(fill, isNot(palette.dangerSoft), reason: reason);
        expect(fill, isNot(palette.danger), reason: reason);
        expect(find.textContaining('08:04'), findsOneWidget, reason: reason);
      },
    );
  });

  testWidgets('the summary counts scheduled doses, not as-needed intakes',
      (tester) async {
    final intake = DoseEventRow(
      id: 'i1',
      profileId: 'self',
      medicationId: 'med-1',
      eventType: 'taken',
      // 09:00 in UTC+4, the same time as the dose: doses come first.
      at: DateTime.utc(2026, 10, 2, 5).microsecondsSinceEpoch,
    );
    await pumpUiMatrix(
      tester,
      (context) => _scrolled(
        DayDetails(
          day: _day([_dose('09:00', DoseStatus.taken)], intakes: [intake]),
          zone: testZone,
        ),
      ),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        final summary = find.byWidgetPredicate(
          (w) =>
              w is StatusPill && w.label != null && w.kind == StatusKind.taken,
        );
        // "Taken 1": one scheduled dose, the intake is listed but not counted.
        expect(
          tester.widgetList<StatusPill>(summary).single.label,
          anyOf('Taken 1', 'Принято 1'),
        );
        final times = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .where((t) => t == '09:00');
        expect(times, hasLength(2));
        // The dose is listed before the intake of the same minute.
        final rows = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .toList();
        final dose = rows.indexOf('Med D 500 mg');
        final asNeeded = rows.indexWhere(
          (t) => t == 'As-needed intake' || t == 'Приём по необходимости',
        );
        expect(dose, greaterThanOrEqualTo(0));
        expect(asNeeded, greaterThan(dose));
      },
    );
  });

  testWidgets('"Taken at" is the label of the pill, said once', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scrolled(
        DayDetails(
          day: _day([
            _dose(
              '08:00',
              DoseStatus.taken,
              markedAt: DateTime.utc(2026, 10, 2, 4, 4),
            ),
          ]),
          zone: testZone,
        ),
      ),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        expect(find.textContaining('08:04'), findsOneWidget);
        final pill = find.byWidgetPredicate(
          (w) => w is StatusPill && (w.label ?? '').contains('08:04'),
        );
        expect(pill, findsOneWidget);
      },
    );
  });

  testWidgets('an anonymous medication shows no dose or strength',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => DayDetails(
        day: _day([_dose('08:00', DoseStatus.taken, redacted: true)]),
        zone: testZone,
      ),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        expect(find.textContaining('tablet'), findsNothing);
        expect(find.textContaining('таблет'), findsNothing);
        expect(find.textContaining('500'), findsNothing);
      },
    );
  });

  testWidgets('a day without entries says so and has no groups',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => DayDetails(day: _day(const []), zone: testZone),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        expect(find.byType(StatusPill), findsNothing);
        expect(find.byKey(const Key('day-part-morning')), findsNothing);
      },
    );
  });
}
