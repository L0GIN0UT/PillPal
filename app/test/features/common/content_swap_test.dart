import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/common/content_swap.dart';
import 'package:pillpal/src/theme/motion.dart';

import 'motion_test_host.dart';

void main() {
  Widget swap(ValueNotifier<bool> second, {bool reduced = false}) {
    return motionApp(
      Align(
        alignment: Alignment.topCenter,
        child: ValueListenableBuilder<bool>(
          valueListenable: second,
          builder: (context, isSecond, _) => ContentSwap(
            child: SizedBox(
              key: ValueKey(isSecond),
              height: isSecond ? 200 : 100,
              child: Text(isSecond ? 'second' : 'first'),
            ),
          ),
        ),
      ),
      reduced: reduced,
    );
  }

  double height(WidgetTester tester) =>
      tester.getSize(find.byType(ContentSwap)).height;

  double opacity(WidgetTester tester, String text) => tester
      .widget<FadeTransition>(
        find
            .ancestor(
              of: find.text(text),
              matching: find.byType(FadeTransition),
            )
            .first,
      )
      .opacity
      .value;

  testWidgets('the old fades out in fast, then resize and fade in in base', (
    tester,
  ) async {
    final second = ValueNotifier<bool>(false);
    addTearDown(second.dispose);
    await tester.pumpWidget(swap(second));
    expect(height(tester), 100);

    second.value = true;
    await tester.pump();
    await tester.pump(PillPalMotion.fast ~/ 2);
    expect(opacity(tester, 'first'), inExclusiveRange(0, 1));
    expect(find.text('second'), findsNothing);
    expect(height(tester), 100);

    // A controller is done on the first frame after its duration.
    await tester.pump(
      PillPalMotion.fast ~/ 2 + const Duration(milliseconds: 1),
    );
    expect(find.text('first'), findsNothing);
    expect(height(tester), 100, reason: 'the resize starts now');
    await tester.pump(PillPalMotion.base ~/ 2);
    expect(opacity(tester, 'second'), inExclusiveRange(0, 1));
    expect(height(tester), inExclusiveRange(100, 200));

    await tester.pump(PillPalMotion.base);
    await tester.pump();
    expect(opacity(tester, 'second'), 1);
    expect(height(tester), 200);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('a rebuild with the same key swaps nothing', (tester) async {
    final label = ValueNotifier<String>('first');
    addTearDown(label.dispose);
    await tester.pumpWidget(
      motionApp(
        ValueListenableBuilder<String>(
          valueListenable: label,
          builder: (context, text, _) => ContentSwap(
            child: SizedBox(
              key: const ValueKey('same'),
              width: 200,
              height: 100,
              child: Text(text),
            ),
          ),
        ),
      ),
    );

    label.value = 'changed';
    await tester.pump();

    expect(find.text('first'), findsNothing);
    expect(opacity(tester, 'changed'), 1);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('reduced motion: the swap is instant', (tester) async {
    final second = ValueNotifier<bool>(false);
    addTearDown(second.dispose);
    await tester.pumpWidget(swap(second, reduced: true));

    second.value = true;
    await tester.pump();
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
    expect(height(tester), 200);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
