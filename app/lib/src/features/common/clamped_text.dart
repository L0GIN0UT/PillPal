import 'package:material_ui/material_ui.dart';

/// Text scaling with a ceiling, for the few texts that must not outgrow their
/// box: screen titles (x1.5), the name in the «Сейчас» card (x1.6), navigation
/// labels (x1.15) and the floating button (x1.3) (B2-README section 9.2 and
/// 9.9). Everything else scales without a limit.
extension TextScaleClamp on BuildContext {
  /// The text scaler of the context, never above [maxScale]; a user who
  /// shrinks the text keeps the smaller size.
  TextScaler clampedTextScaler(double maxScale) =>
      MediaQuery.textScalerOf(this).clamp(maxScaleFactor: maxScale);
}

/// A [Text] whose scale is capped at [maxScale]. A word that still does not
/// fit breaks inside the word: the text engine does that on its own, so the
/// last resort of section 9.2 needs no code here.
///
/// Give [key] to the widget; the plain [Text] inside carries [data], so
/// `find.text(name)` finds it.
class ClampedText extends StatelessWidget {
  /// Creates the text.
  const ClampedText(
    this.data, {
    required this.maxScale,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.semanticsLabel,
    super.key,
  });

  /// The text to show.
  final String data;

  /// Largest text scale factor.
  final double maxScale;

  /// Style; the theme's default text style when null.
  final TextStyle? style;

  /// Horizontal alignment.
  final TextAlign? textAlign;

  /// Line limit.
  final int? maxLines;

  /// What to do with text that does not fit.
  final TextOverflow? overflow;

  /// Whether the text wraps.
  final bool? softWrap;

  /// What screen readers say instead of [data].
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Text(
      data,
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      semanticsLabel: semanticsLabel,
      textScaler: context.clampedTextScaler(maxScale),
    );
  }
}
