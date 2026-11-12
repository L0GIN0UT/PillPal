import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/common/sheet_scaffold.dart';
import 'package:pillpal/src/theme/motion.dart';

import 'motion_test_host.dart';

void main() {
  const content = Key('sheet-content');

  Widget opener() => Builder(
        builder: (context) => TextButton(
          key: const Key('open'),
          onPressed: () => showPillPalSheet<void>(
            context,
            (_) => const SheetScaffold(
              children: [SizedBox(key: content, height: 100)],
            ),
          ),
          child: const Text('open'),
        ),
      );

  testWidgets('slides up in slow and closes in base', (tester) async {
    await tester.pumpWidget(motionApp(opener()));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    final start = tester.getTopLeft(find.byKey(content)).dy;

    final route = ModalRoute.of(tester.element(find.byKey(content)))!;
    expect(route.transitionDuration, PillPalMotion.slow);
    expect(route.reverseTransitionDuration, PillPalMotion.base);

    await tester.pump(PillPalMotion.slow);
    expect(tester.getTopLeft(find.byKey(content)).dy, lessThan(start));

    // The way down takes `base`: still on screen 40 ms before it ends.
    Navigator.of(tester.element(find.byKey(content))).pop();
    await tester.pump();
    await tester.pump(PillPalMotion.base - const Duration(milliseconds: 40));
    expect(find.byKey(content), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byKey(content), findsNothing);
  });
}
