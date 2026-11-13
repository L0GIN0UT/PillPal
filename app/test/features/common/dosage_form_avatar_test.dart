import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/common/dosage_form.dart';
import 'package:pillpal/src/features/common/dosage_form_avatar.dart';
import 'package:pillpal/src/theme/app_theme.dart';

import 'common_test_host.dart';

// The disc of a medication row: Material icons where one reads as the form,
// drawn glyphs for the tablet and the capsule (the Material candidates look
// like a radio button and a switch), all in the icon colour of the disc.

Finder _painted(DosageForm form) => find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint &&
          widget.painter is DosageGlyphPainter &&
          (widget.painter! as DosageGlyphPainter).form == form,
    );

void main() {
  const icons = {
    DosageForm.liquid: Icons.medication_liquid_outlined,
    DosageForm.injection: Icons.vaccines_outlined,
    DosageForm.ointment: Icons.sanitizer_outlined,
    DosageForm.spray: Icons.air,
    DosageForm.powder: Icons.grain,
    DosageForm.generic: Icons.medication_outlined,
  };

  for (final MapEntry(key: form, value: icon) in icons.entries) {
    testWidgets('${form.name} shows its Material icon', (tester) async {
      await pumpThemed(tester, DosageFormAvatar(form: form));

      final shown = tester.widget<Icon>(find.byType(Icon));
      expect(shown.icon, icon);
      expect(shown.color, paletteOf().onActionSoft);
      expect(find.byType(DosageFormAvatar), findsOneWidget);
    });
  }

  for (final form in const [DosageForm.tablet, DosageForm.capsule]) {
    testWidgets('${form.name} is drawn, not a Material icon', (tester) async {
      await pumpThemed(tester, DosageFormAvatar(form: form));

      expect(find.byType(Icon), findsNothing);
      expect(_painted(form), findsOneWidget);
      final painter = tester.widget<CustomPaint>(_painted(form)).painter!
          as DosageGlyphPainter;
      expect(painter.color, paletteOf().onActionSoft);
      expect(
        tester.getSize(_painted(form)),
        const Size.square(PillPalSizes.iconInline),
      );
    });
  }

  testWidgets('the disc is 40 and says nothing to screen readers',
      (tester) async {
    await pumpThemed(tester, const DosageFormAvatar(form: DosageForm.tablet));

    expect(
      tester.getSize(find.byType(DosageFormAvatar)),
      const Size.square(PillPalSizes.avatarSm),
    );
    expect(
      find.descendant(
        of: find.byType(DosageFormAvatar),
        matching: find.byType(ExcludeSemantics),
      ),
      findsOneWidget,
    );
  });

  test('the painter repaints only for another form or colour', () {
    const a = DosageGlyphPainter(form: DosageForm.tablet, color: Colors.red);
    expect(
      a.shouldRepaint(
        const DosageGlyphPainter(form: DosageForm.tablet, color: Colors.red),
      ),
      isFalse,
    );
    expect(
      a.shouldRepaint(
        const DosageGlyphPainter(form: DosageForm.capsule, color: Colors.red),
      ),
      isTrue,
    );
  });
}
