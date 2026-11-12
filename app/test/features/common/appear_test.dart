import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/common/pillpal_banner.dart';
import 'package:pillpal/src/theme/motion.dart';

import 'motion_test_host.dart';

void main() {
  const banner = Key('banner');

  double opacity(WidgetTester tester) => tester
      .widget<Opacity>(
        find
            .descendant(
              of: find.byKey(banner),
              matching: find.byType(Opacity),
            )
            .first,
      )
      .opacity;

  /// How far down the banner is from its place (negative: above it).
  double shift(WidgetTester tester) => tester
      .widget<Transform>(
        find
            .descendant(
              of: find.byKey(banner),
              matching: find.byType(Transform),
            )
            .first,
      )
      .transform
      .getTranslation()
      .y;

  Widget shown() => const PillPalBanner(key: banner, body: 'Note');

  testWidgets('slides down 16 px and fades in, in base', (tester) async {
    await tester.pumpWidget(motionApp(shown()));
    expect(opacity(tester), 0);
    expect(shift(tester), -16);

    await tester.pump(PillPalMotion.base ~/ 5);
    expect(opacity(tester), inExclusiveRange(0, 1));
    expect(shift(tester), inExclusiveRange(-16, 0));

    await tester.pump(PillPalMotion.base);
    expect(opacity(tester), 1);
    expect(shift(tester), 0);
  });

  testWidgets('keeps its semantics and a tap target from the first frame', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(motionApp(shown()));

    expect(find.bySemanticsLabel('Note'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('plays once: a rebuild does not replay it', (tester) async {
    final tick = ValueNotifier<int>(0);
    addTearDown(tick.dispose);
    await tester.pumpWidget(
      motionApp(
        ValueListenableBuilder<int>(
          valueListenable: tick,
          builder: (context, _, __) => shown(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tick.value++;
    await tester.pump();
    expect(opacity(tester), 1);
  });

  testWidgets('reduced motion: fades in place, in fast', (tester) async {
    await tester.pumpWidget(motionApp(shown(), reduced: true));
    await tester.pump(PillPalMotion.fast ~/ 3);

    expect(opacity(tester), inExclusiveRange(0, 1));
    expect(shift(tester), 0);
    await tester.pump(PillPalMotion.fast);
    expect(opacity(tester), 1);
  });
}
