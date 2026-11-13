import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import 'dosage_form.dart';

/// The soft 40 disc of a medication row with the glyph of its dosage
/// [form]: a search result, a medication card. Decorative: the row's text
/// names the form.
class DosageFormAvatar extends StatelessWidget {
  /// Creates the disc.
  const DosageFormAvatar({required this.form, super.key});

  /// What the glyph shows.
  final DosageForm form;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final icon = dosageFormIcon(form);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: palette.actionSoft,
        shape: const CircleBorder(),
      ),
      child: SizedBox.square(
        dimension: PillPalSizes.avatarSm,
        child: ExcludeSemantics(
          child: Center(
            child: icon != null
                ? Icon(
                    icon,
                    size: PillPalSizes.iconInline,
                    color: palette.onActionSoft,
                  )
                : CustomPaint(
                    size: const Size.square(PillPalSizes.iconInline),
                    painter: DosageGlyphPainter(
                      form: form,
                      color: palette.onActionSoft,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// The Material icon of [form], or null for a form drawn by
/// [DosageGlyphPainter] (no Material icon reads as a tablet or a capsule
/// without looking like a control).
IconData? dosageFormIcon(DosageForm form) => switch (form) {
      DosageForm.tablet || DosageForm.capsule => null,
      DosageForm.liquid => Icons.medication_liquid_outlined,
      DosageForm.injection => Icons.vaccines_outlined,
      DosageForm.ointment => Icons.sanitizer_outlined,
      DosageForm.spray => Icons.air,
      DosageForm.powder => Icons.grain,
      DosageForm.generic => Icons.medication_outlined,
    };

/// Draws the tablet (a disc with a score line) and the capsule (two halves
/// on a diagonal, one filled) in the 24 grid of the Material icons, so they
/// sit beside them in weight and size.
class DosageGlyphPainter extends CustomPainter {
  /// Creates the painter.
  const DosageGlyphPainter({required this.form, required this.color});

  /// [DosageForm.tablet] or [DosageForm.capsule]; anything else paints
  /// nothing.
  final DosageForm form;

  /// The stroke and fill colour.
  final Color color;

  static const double _grid = 24;
  static const double _stroke = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.shortestSide / _grid;
    canvas
      ..save()
      ..scale(unit);
    final outline = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;
    switch (form) {
      case DosageForm.tablet:
        _tablet(canvas, outline);
      case DosageForm.capsule:
        _capsule(canvas, outline);
      case _:
        break;
    }
    canvas.restore();
  }

  void _tablet(Canvas canvas, Paint outline) {
    const center = Offset(_grid / 2, _grid / 2);
    canvas
      ..drawCircle(center, 8, outline)
      ..drawLine(const Offset(7.5, 16.5), const Offset(16.5, 7.5), outline);
  }

  void _capsule(Canvas canvas, Paint outline) {
    const half = _grid / 2;
    final body = RRect.fromRectAndRadius(
      const Rect.fromLTRB(half - 4.5, half - 9, half + 4.5, half + 9),
      const Radius.circular(4.5),
    );
    canvas
      ..translate(half, half)
      ..rotate(math.pi / 4)
      ..translate(-half, -half)
      ..save()
      ..clipRRect(body)
      ..drawRect(
        const Rect.fromLTRB(0, half, _grid, _grid),
        Paint()..color = color,
      )
      ..restore()
      ..drawRRect(body, outline)
      ..drawLine(
        const Offset(half - 4.5, half),
        const Offset(half + 4.5, half),
        outline,
      );
  }

  @override
  bool shouldRepaint(DosageGlyphPainter oldDelegate) =>
      oldDelegate.form != form || oldDelegate.color != color;
}
