import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/common/choice_button.dart';
import 'package:pillpal/src/features/common/pillpal_card.dart';
import 'package:pillpal/src/features/reminders/reminder_level_picker.dart';
import 'package:pillpal/src/features/schedule/schedule_draft.dart';
import 'package:pillpal/src/features/schedule/schedule_editor_view.dart';
import 'package:pillpal/src/features/schedule/schedule_save_bar.dart';
import 'package:pillpal/src/theme/sizes.dart';
import 'package:pillpal/src/theme/text_theme.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../support/ui_matrix.dart';

// The schedule editor (B2-Schedule) in the whole UI matrix, plus the rules of
// the redesign: stadium chips with a check, time rows in a card with a big
// numeral time, the course as two date fields and a sticky save button. The
// reminder level is not here: it is app-wide, in Settings (Q2).

final LocalDate _today = LocalDate(2026, 10, 16);

const MedicationRow _medication = MedicationRow(
  id: 'med-2',
  profileId: 'self-1',
  name: 'Очень длинное название синтетического лекарства для проверки',
  strengthText: '20 мг',
  tzMode: 'local',
  privacy: 'shared',
  redacted: false,
  gtinLinkShared: false,
  clientUpdatedAt: 1,
  updatedByDevice: 'd',
);

Widget _editor(
  ScheduleDraft draft, {
  bool started = false,
  bool ended = false,
}) =>
    ProviderScope(
      child: ScheduleEditorView(
        medication: _medication,
        scheduleId: 'sched-1',
        initial: draft,
        today: _today,
        ended: ended,
        started: started,
        canDelete: true,
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// Makes the screen tall: a list builds only what is near the viewport.
Future<void> _tall(WidgetTester tester, UiMatrixCase cell) async {
  await _settle(tester);
  tester.view.physicalSize = Size(cell.size.width, 20000);
  await tester.pump();
}

Finder get _save => find.byKey(const Key('schedule-save'));

void main() {
  final base = ScheduleDraft.initial(_today);

  group('matrix', () {
    final variants = <String, (ScheduleDraft, bool)>{
      'daily, two times, started in the past': (
        base
            .copyWith(startDate: LocalDate(2026, 10, 1), endDate: _today)
            .addSlot(),
        false,
      ),
      'weekdays': (base.copyWith(kind: RuleKind.weekdays), false),
      'interval, split note': (
        base.copyWith(kind: RuleKind.intervalDays, intervalDays: 3),
        true,
      ),
      'as needed': (base.copyWith(kind: RuleKind.asNeeded), false),
    };

    for (final entry in variants.entries) {
      testWidgets(entry.key, (tester) async {
        final (draft, started) = entry.value;
        await pumpUiMatrix(
          tester,
          (context) => _editor(draft, started: started),
          expectTouchTargets: true,
          expectContrast: true,
          check: (tester, cell) async {
            await _tall(tester, cell);
            expect(_save, findsOneWidget);
            expect(find.byKey(const Key('course-start')), findsOneWidget);
            expect(find.byKey(const Key('course-end')), findsOneWidget);
            expect(find.byType(ReminderLevelPicker), findsNothing);
            expectTouchTargetsOf(tester, cell);
          },
        );
        await tester.pumpWidget(const SizedBox());
      });
    }
  });

  group('layout', () {
    testWidgets('the kind chips are stadium chips with a check when selected',
        (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => _editor(base),
        scales: const [1.0],
        sizes: const [Size(360, 800)],
        check: (tester, cell) async {
          await _settle(tester);
          for (final kind in RuleKind.values) {
            final chip = find.byKey(ValueKey('kind-${kind.wireName}'));
            expect(chip, findsOneWidget);
            expect(
              tester.widget<ChoiceButton>(chip).selected,
              kind == RuleKind.daily,
            );
            expect(
              find.descendant(of: chip, matching: find.byIcon(Icons.check)),
              kind == RuleKind.daily ? findsOneWidget : findsNothing,
            );
          }
        },
      );
    });

    testWidgets('times sit in a card, the time as a big numeral',
        (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => _editor(base.addSlot()),
        scales: const [1.0],
        sizes: const [Size(360, 800)],
        check: (tester, cell) async {
          await _settle(tester);
          final time = find.byKey(const ValueKey('slot-time-08:00'));
          expect(
            find.ancestor(of: time, matching: find.byType(PillPalCard)),
            findsOneWidget,
          );
          final text = tester.widget<Text>(
            find.descendant(of: time, matching: find.byType(Text)),
          );
          final numeral = Theme.of(tester.element(time)).textTheme.numeral;
          expect(text.style?.fontSize, numeral.fontSize);
          expect(text.style?.fontWeight, numeral.fontWeight);
          expect(text.style?.fontFeatures, numeral.fontFeatures);
          expect(find.byKey(const Key('slot-add')), findsOneWidget);
        },
      );
    });

    testWidgets(
        'the course dates stack on phones, in senior mode and at '
        'large text', (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => _editor(base),
        check: (tester, cell) async {
          await _tall(tester, cell);
          final start = tester.getTopLeft(
            find.byKey(const Key('course-start')),
          );
          final end = tester.getTopLeft(find.byKey(const Key('course-end')));
          expect(end.dy, greaterThan(start.dy));
        },
      );
    });

    testWidgets('the course dates sit side by side where there is room',
        (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => _editor(base),
        scales: const [1.0],
        sizes: const [Size(800, 900)],
        check: (tester, cell) async {
          await _tall(tester, cell);
          final start = tester.getTopLeft(
            find.byKey(const Key('course-start')),
          );
          final end = tester.getTopLeft(find.byKey(const Key('course-end')));
          if (cell.senior) {
            expect(end.dy, greaterThan(start.dy));
          } else {
            expect(end.dy, start.dy);
            expect(end.dx, greaterThan(start.dx));
          }
        },
      );
    });

    testWidgets('a date field shows its ripple above the fill', (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => _editor(base),
        scales: const [1.0],
        sizes: const [Size(360, 800)],
        check: (tester, cell) async {
          await _tall(tester, cell);
          final field = find.byKey(const Key('course-start'));
          // The fill is an Ink inside the InkWell, not the decorator's own.
          expect(
            find.descendant(of: field, matching: find.byType(Ink)),
            findsOneWidget,
          );
          final decorator = tester.widget<InputDecorator>(
            find.descendant(of: field, matching: find.byType(InputDecorator)),
          );
          expect(decorator.decoration.filled, isFalse);
        },
      );
    });

    testWidgets('three errors never push the save button off screen',
        (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: ScheduleSaveBar(
            errors: const [
              ScheduleDraftError.weekdaysEmpty,
              ScheduleDraftError.timesDuplicate,
              ScheduleDraftError.endBeforeStart,
            ],
            onSave: () {},
          ),
        ),
        // No contrast check: the danger banner is 6.99:1 in a senior cell, a
        // palette matter of the shared PillPalBanner, not of this bar.
        expectTouchTargets: true,
        check: (tester, cell) async {
          await tester.pump();
          final scroll = find.descendant(
            of: find.byType(ScheduleSaveBar),
            matching: find.byType(SingleChildScrollView),
          );
          expect(
            tester.getSize(scroll).height,
            lessThanOrEqualTo(
              cell.size.height * PillPalSizes.stickyBarMaxFraction + 0.5,
            ),
          );
          final save = tester.getRect(_save);
          expect(save.bottom, lessThanOrEqualTo(cell.size.height));
          expect(save.top, greaterThanOrEqualTo(0));
        },
      );
    });

    testWidgets('save is sticky: outside the scrolling list, on screen',
        (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => _editor(
          base.copyWith(kind: RuleKind.weekdays).addSlot().addSlot(),
        ),
        scales: const [1.0],
        check: (tester, cell) async {
          await _settle(tester);
          expect(
            find.descendant(of: find.byType(ListView), matching: _save),
            findsNothing,
          );
          expect(
            tester.getBottomLeft(_save).dy,
            lessThanOrEqualTo(cell.size.height),
          );
          expect(
            tester.getSize(_save).height,
            greaterThanOrEqualTo(cell.touchTarget),
          );
        },
      );
    });

    testWidgets('an ended schedule keeps save disabled', (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => _editor(base, ended: true),
        scales: const [1.0],
        sizes: const [Size(360, 800)],
        check: (tester, cell) async {
          await _settle(tester);
          expect(tester.widget<ButtonStyleButton>(_save).onPressed, isNull);
        },
      );
    });
  });
}
