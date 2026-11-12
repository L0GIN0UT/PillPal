import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/common/show_pillpal_dialog.dart';
import 'package:pillpal/src/theme/motion.dart';

import 'motion_test_host.dart';

void main() {
  const content = Key('dialog-content');

  Widget opener() => Builder(
        builder: (context) => TextButton(
          key: const Key('open'),
          onPressed: () => showPillPalDialog<void>(
            context: context,
            builder: (_) => const Dialog(
              child: SizedBox(key: content, width: 200, height: 100),
            ),
          ),
          child: const Text('open'),
        ),
      );

  double scale(WidgetTester tester) => tester
      .widget<ScaleTransition>(
        find
            .ancestor(
              of: find.byKey(content),
              matching: find.byType(ScaleTransition),
            )
            .first,
      )
      .scale
      .value;

  double opacity(WidgetTester tester) => tester
      .widget<FadeTransition>(
        find
            .ancestor(
              of: find.byKey(content),
              matching: find.byType(FadeTransition),
            )
            .first,
      )
      .opacity
      .value;

  testWidgets('fades in and grows from 0.96 in base, leaves in fast', (
    tester,
  ) async {
    await tester.pumpWidget(motionApp(opener()));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    await tester.pump(PillPalMotion.base ~/ 10);

    expect(scale(tester), inExclusiveRange(0.96, 1));
    expect(opacity(tester), inExclusiveRange(0, 1));

    // Not finished at `fast`: the way in takes `base`.
    await tester.pump(PillPalMotion.fast);
    expect(opacity(tester), lessThan(1));
    await tester.pump(PillPalMotion.base);
    expect(scale(tester), 1);
    expect(opacity(tester), 1);

    Navigator.of(tester.element(find.byKey(content))).pop();
    await tester.pump();
    await tester.pump(PillPalMotion.fast + const Duration(milliseconds: 1));
    expect(find.byKey(content), findsNothing);
  });

  testWidgets('reduced motion: fades only, no scale, near-instant', (
    tester,
  ) async {
    useSystemReducedMotion(tester);
    await tester.pumpWidget(motionApp(opener()));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(
      find.ancestor(
        of: find.byKey(content),
        matching: find.byType(ScaleTransition),
      ),
      findsNothing,
    );
    expect(opacity(tester), inExclusiveRange(0, 1));
    // The system flag runs the route at 5 % of `base`.
    await tester.pump(PillPalMotion.fast ~/ 3);
    expect(opacity(tester), 1);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('the scrim is the dialog theme scrim', (tester) async {
    await tester.pumpWidget(motionApp(opener()));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();

    final theme = Theme.of(tester.element(find.byKey(content)));
    expect(theme.dialogTheme.barrierColor, isNotNull);
    final barrier = tester.widget<ModalBarrier>(
      find.byWidgetPredicate(
        (w) => w is ModalBarrier && w.color == theme.dialogTheme.barrierColor,
      ),
    );
    expect(barrier.color, isNot(Colors.black54));
    final route = ModalRoute.of(tester.element(find.byKey(content)))!;
    expect(
      (route as PopupRoute<void>).barrierColor,
      theme.dialogTheme.barrierColor,
    );
  });

  testWidgets('focus stays inside the dialog', (tester) async {
    await tester.pumpWidget(motionApp(opener()));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();

    final route = ModalRoute.of(tester.element(find.byKey(content)))!;
    expect(
      (route as ModalRoute<void>).traversalEdgeBehavior,
      TraversalEdgeBehavior.closedLoop,
    );
  });

  testWidgets('a dialog that is not dismissible stays on a barrier tap', (
    tester,
  ) async {
    await tester.pumpWidget(
      motionApp(
        Builder(
          builder: (context) => TextButton(
            key: const Key('open'),
            onPressed: () => showPillPalDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => const Dialog(
                child: SizedBox(key: content, width: 200, height: 100),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.byKey(content), findsOneWidget);
  });

  testWidgets('a dismissible dialog closes on a barrier tap', (tester) async {
    await tester.pumpWidget(motionApp(opener()));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.byKey(content), findsNothing);
  });

  testWidgets('resolves with the value popped', (tester) async {
    Future<String?>? result;
    await tester.pumpWidget(
      motionApp(
        Builder(
          builder: (context) => TextButton(
            key: const Key('open'),
            onPressed: () => result = showPillPalDialog<String>(
              context: context,
              builder: (dialogContext) => Dialog(
                child: TextButton(
                  key: const Key('pick'),
                  onPressed: () => Navigator.of(dialogContext).pop('picked'),
                  child: const Text('pick'),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick')));
    await tester.pumpAndSettle();

    expect(await result, 'picked');
  });
}
