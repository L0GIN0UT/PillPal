import 'package:material_ui/material_ui.dart';

import 'compact_text.dart';

/// The width of the longest word of [text] in [style] at the text scale of
/// [context] (or [scaler]): the narrowest a paragraph can get before a word
/// breaks inside, one or two letters per line (docs/design.md, narrow
/// screens).
double longestWordWidth(
  BuildContext context,
  String text,
  TextStyle? style, {
  TextScaler? scaler,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: scaler ?? MediaQuery.textScalerOf(context),
  )..layout();
  final width = painter.minIntrinsicWidth;
  painter.dispose();
  return width;
}

/// Whether every word of every text in [texts] fits on a line [width] wide.
/// An unbounded [width] always fits.
bool wordsFit(
  BuildContext context,
  double width,
  Iterable<(String, TextStyle?)> texts,
) {
  if (!width.isFinite) {
    return true;
  }
  for (final (text, style) in texts) {
    if (longestWordWidth(context, text, style) > width) {
      return false;
    }
  }
  return true;
}

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
