import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/shell/pillpal_navigation_bar.dart';
import 'package:pillpal/src/theme/sizes.dart';

import '../support/ui_matrix.dart';

// The bottom navigation (docs/redesign-plan.md, R3a; B2 README sections 3 and
// 9.9): labels stop growing at x1.15, the full label is the tooltip, and the
// selected destination is a tonal shape around the icon and its label.

Widget _bar(ValueChanged<int> onSelected, {int selected = 0}) => SizedBox(
      width: double.infinity,
      child: PillPalNavigationBar(
        selectedIndex: selected,
        onSelected: onSelected,
      ),
    );

void main() {
  testWidgets('labels are clamped to x1.15 and keep the full text as tooltip',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _bar((_) {}),
      scales: const [1.0, 2.0],
      expectTouchTargets: true,
      check: (tester, cell) async {
        final reason = 'in "${cell.label}"';
        final label = find.byType(Text).first;
        final scaler = MediaQuery.textScalerOf(tester.element(label));
        // A text of size 100 shows the factor: never above the clamp (the
        // senior multiplier included), never above the system scale.
        final shown = scaler.scale(100) / 100;
        final system =
            cell.scale * (cell.senior ? PillPalSizes.seniorTextScale : 1);
        final ceiling = cell.senior
            ? PillPalSizes.navLabelSeniorMaxScale
            : PillPalSizes.navLabelMaxScale;
        expect(shown, closeTo(system < ceiling ? system : ceiling, 0.001),
            reason: reason);

        expect(find.byType(NavigationBar), findsOneWidget, reason: reason);
        expect(find.byType(NavigationDestination), findsNWidgets(4),
            reason: reason);
        // Long press shows the whole label: every destination has a tooltip
        // equal to its text.
        final labels = [
          for (final text in tester.widgetList<Text>(find.byType(Text)))
            if (text.data!.isNotEmpty) text.data!,
        ];
        expect(labels, hasLength(4), reason: reason);
        for (final label in labels) {
          expect(find.byTooltip(label), findsOneWidget, reason: reason);
        }
      },
    );
  });

  testWidgets('no label is cut, in Russian at 320 px in senior mode too',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _bar((_) {}),
      scales: const [1.0, 2.0],
      sizes: const [Size(320, 568)],
      check: (tester, cell) async {
        for (final label in tester.widgetList<Text>(find.byType(Text))) {
          if (label.data!.isEmpty) {
            continue;
          }
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(label.data!),
          );
          expect(paragraph.didExceedMaxLines, isFalse,
              reason: '"${label.data}" is cut in "${cell.label}"');
        }
      },
    );
  });

  testWidgets('the indicator surrounds the icon and the label', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _bar((_) {}, selected: 1),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        final reason = 'in "${cell.label}"';
        final selected = find.byKey(const Key('nav-indicator-1'));
        expect(selected, findsOneWidget, reason: reason);
        expect(find.descendant(of: selected, matching: find.byType(Icon)),
            findsOneWidget,
            reason: reason);
        expect(find.descendant(of: selected, matching: find.byType(Text)),
            findsOneWidget,
            reason: reason);
        final indicator = tester.getRect(selected);
        final text = tester.getRect(
          find.descendant(of: selected, matching: find.byType(Text)),
        );
        // Rect.contains leaves out the far edges: compare the edges.
        expect(text.left, greaterThanOrEqualTo(indicator.left), reason: reason);
        expect(text.right, lessThanOrEqualTo(indicator.right), reason: reason);
        expect(text.top, greaterThanOrEqualTo(indicator.top), reason: reason);
        expect(text.bottom, lessThanOrEqualTo(indicator.bottom),
            reason: reason);
        // Unselected destinations have no indicator.
        expect(find.byKey(const Key('nav-indicator-0')), findsNothing,
            reason: reason);
      },
    );
  });

  testWidgets('tapping a destination reports its index', (tester) async {
    final taps = <int>[];
    await pumpUiMatrix(
      tester,
      (context) => _bar(taps.add),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        taps.clear();
        await tester.tap(find.byType(NavigationDestination).at(2));
        expect(taps, [2], reason: 'in "${cell.label}"');
      },
    );
  });
}
