import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/common/round_check_button.dart';
import 'package:pillpal/src/theme/motion.dart';
import 'package:pillpal/src/theme/sizes.dart';

import '../../support/ui_matrix.dart';
import 'common_test_host.dart';

const _key = Key('dose-take-s1/2026-11-10T08:00');
const _label = 'Mark Magnesium as taken';

Widget _button({VoidCallback? onPressed}) => RoundCheckButton(
      key: _key,
      label: _label,
      onPressed: onPressed ?? () {},
    );

Material _material(WidgetTester tester) => tester.widget<Material>(
      find
          .descendant(of: find.byKey(_key), matching: find.byType(Material))
          .first,
    );

void main() {
  testWidgets('is a 48 circle in normal mode', (tester) async {
    await pumpThemed(tester, _button());
    expect(
      tester.getSize(find.byKey(_key)),
      const Size.square(PillPalSizes.roundCheck),
    );
  });

  testWidgets('is a 64 target in senior mode', (tester) async {
    await pumpThemed(tester, _button(), senior: true);
    expect(
      tester.getSize(find.byKey(_key)),
      const Size.square(PillPalSizes.seniorButtonHeight),
    );
  });

  testWidgets('draws a 2 px outline ring and the muted check', (tester) async {
    await pumpThemed(tester, _button());
    final p = paletteOf();
    final shape = _material(tester).shape! as CircleBorder;
    expect(shape.side.color, p.outline);
    expect(shape.side.width, PillPalSizes.outline);
    expect(_material(tester).color, Colors.transparent);
    expect(tester.widget<Icon>(find.byIcon(Icons.check)).color, p.inkMuted);
  });

  testWidgets('turns action while pressed', (tester) async {
    await pumpThemed(tester, _button());
    final p = paletteOf();
    final gesture =
        await tester.startGesture(tester.getCenter(find.byKey(_key)));
    await tester.pump();
    expect(_material(tester).color, p.action);
    // The check eases to its pressed colour in `base`.
    await tester.pump(PillPalMotion.base);
    expect(tester.widget<Icon>(find.byIcon(Icons.check)).color, p.onAction);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('the check eases between its colours, not at once',
      (tester) async {
    await pumpThemed(tester, _button());
    final p = paletteOf();
    final gesture =
        await tester.startGesture(tester.getCenter(find.byKey(_key)));
    await tester.pump();
    await tester.pump(PillPalMotion.base ~/ 2);
    final mid = tester.widget<Icon>(find.byIcon(Icons.check)).color;
    expect(mid, isNot(p.inkMuted));
    expect(mid, isNot(p.onAction));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('reduced motion changes the check at once', (tester) async {
    await pumpThemed(
      tester,
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: _button(),
        ),
      ),
    );
    final p = paletteOf();
    final gesture =
        await tester.startGesture(tester.getCenter(find.byKey(_key)));
    await tester.pump();
    expect(tester.widget<Icon>(find.byIcon(Icons.check)).color, p.onAction);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('calls onPressed once per tap', (tester) async {
    var taps = 0;
    await pumpThemed(tester, _button(onPressed: () => taps++));
    await tester.tap(find.byKey(_key));
    expect(taps, 1);
  });

  testWidgets('is a labelled button for screen readers', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpThemed(tester, _button());
    expect(
      tester.getSemantics(find.byKey(_key)),
      matchesSemantics(label: _label, isButton: true, hasTapAction: true),
    );
    handle.dispose();
  });

  testWidgets('meets the touch target in the whole matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _button(),
      expectTouchTargets: true,
      expectContrast: true,
    );
  });
}
