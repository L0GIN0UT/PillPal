import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/common/clamped_text.dart';
import 'package:pillpal/src/theme/sizes.dart';

import 'common_test_host.dart';

/// The size the text is drawn at when its style says 10.
double _fontSize(WidgetTester tester, Finder text) =>
    tester.widget<Text>(text).textScaler!.scale(10);

void main() {
  testWidgets('scales like normal text below the clamp', (tester) async {
    await pumpThemed(
      tester,
      const ClampedText('Today', maxScale: PillPalSizes.titleMaxScale),
      scale: 1.2,
    );
    expect(_fontSize(tester, find.text('Today')), closeTo(12, 0.01));
  });

  testWidgets('stops growing at the clamp', (tester) async {
    await pumpThemed(
      tester,
      const ClampedText('Today', maxScale: PillPalSizes.titleMaxScale),
      scale: 2,
    );
    expect(
      _fontSize(tester, find.text('Today')),
      closeTo(10 * PillPalSizes.titleMaxScale, 0.01),
    );
  });

  testWidgets('does not shrink text below scale 1', (tester) async {
    await pumpThemed(
      tester,
      const ClampedText('Today', maxScale: PillPalSizes.titleMaxScale),
      scale: 0.8,
    );
    expect(_fontSize(tester, find.text('Today')), closeTo(8, 0.01));
  });

  testWidgets('passes style, alignment, lines and key to the text',
      (tester) async {
    await pumpThemed(
      tester,
      const ClampedText(
        'Enalapril',
        key: Key('hero-name'),
        maxScale: PillPalSizes.heroNameMaxScale,
        style: TextStyle(fontSize: 26),
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
    final text = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('hero-name')),
        matching: find.byType(Text),
      ),
    );
    expect(text.data, 'Enalapril');
    expect(text.style?.fontSize, 26);
    expect(text.textAlign, TextAlign.center);
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('the extension clamps the scaler of the context', (tester) async {
    late TextScaler scaler;
    await pumpThemed(
      tester,
      Builder(
        builder: (context) {
          scaler = context.clampedTextScaler(PillPalSizes.navLabelMaxScale);
          return const SizedBox.shrink();
        },
      ),
      scale: 2,
    );
    expect(scaler.scale(10), closeTo(10 * PillPalSizes.navLabelMaxScale, 0.01));
  });

  testWidgets('a long word wraps inside a narrow box without overflow',
      (tester) async {
    await pumpThemed(
      tester,
      const SizedBox(
        width: 120,
        child: ClampedText(
          'Эналаприлгидрохлоротиазид',
          maxScale: PillPalSizes.heroNameMaxScale,
          style: TextStyle(fontSize: 26),
        ),
      ),
      scale: 2,
      size: const Size(320, 568),
    );
    expect(tester.takeException(), isNull);
  });
}
