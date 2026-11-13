import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'compact_text.dart';

/// The width of the longest word of [text] in [style] (merged into the
/// ambient `DefaultTextStyle`, in the locale of [context]) at the text scale
/// of [context] or [scaler]: the narrowest a paragraph can get before a word
/// breaks inside, one or two letters per line (docs/design.md, narrow
/// screens).
double longestWordWidth(
  BuildContext context,
  String text,
  TextStyle? style, {
  TextScaler? scaler,
}) {
  final painter = _painter(context, text, style, scaler)..layout();
  final width = painter.minIntrinsicWidth;
  painter.dispose();
  return width;
}

/// The width of [text] in [style] on one line, measured like
/// [longestWordWidth].
double lineWidth(BuildContext context, String text, TextStyle? style) {
  final painter = _painter(context, text, style, null)..layout();
  final width = painter.maxIntrinsicWidth;
  painter.dispose();
  return width;
}

TextPainter _painter(
  BuildContext context,
  String text,
  TextStyle? style,
  TextScaler? scaler,
) =>
    TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      textDirection: Directionality.of(context),
      locale: Localizations.maybeLocaleOf(context),
      textScaler: scaler ?? MediaQuery.textScalerOf(context),
    );

/// The widest word of all [texts]: measure once, then compare it with every
/// width a layout may offer.
double longestWordOf(
  BuildContext context,
  Iterable<(String, TextStyle?)> texts,
) {
  var widest = 0.0;
  for (final (text, style) in texts) {
    widest = math.max(widest, longestWordWidth(context, text, style));
  }
  return widest;
}

/// Whether every word of every text in [texts] fits on a line [width] wide.
/// An unbounded [width] always fits.
bool wordsFit(
  BuildContext context,
  double width,
  Iterable<(String, TextStyle?)> texts,
) =>
    !width.isFinite || longestWordOf(context, texts) <= width;

/// Whether a row lays out compactly: from the compact text scale on, and on
/// a screen so narrow that its [texts] would break inside a word beside the
/// parts that take [reserved] of its [width] (a tile, a chevron, a trailing
/// control). A compact row drops its decorations and stacks its parts.
bool rowIsCompact(
  BuildContext context, {
  required double width,
  required double reserved,
  required Iterable<(String, TextStyle?)> texts,
}) =>
    isCompactText(context) || !wordsFit(context, width - reserved, texts);
