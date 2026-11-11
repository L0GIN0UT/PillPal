import 'package:flutter/material.dart';

import '../../theme/spacing.dart';
import '../common/gap.dart';

/// A quiet line of a Family row with a leading glyph (the next dose, how old
/// the data is). Like `IconLabel` but only as wide as its text, so the status
/// pill beside it keeps its place at the end of the row; the glyph grows with
/// the text scale and the text wraps.
class DayHint extends StatelessWidget {
  /// Creates the hint.
  const DayHint({required this.icon, required this.text, super.key});

  /// Leading glyph.
  final IconData icon;

  /// The text.
  final String text;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: MediaQuery.textScalerOf(context)
              .scale(style?.fontSize ?? kDefaultFontSize),
          color: style?.color,
        ),
        const Gap.h(PillPalSpacing.xs),
        Flexible(child: Text(text, style: style)),
      ],
    );
  }
}
