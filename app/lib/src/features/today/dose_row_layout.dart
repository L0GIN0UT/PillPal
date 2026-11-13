import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../common/compact_rows.dart';
import '../common/gap.dart';
import '../common/text_fit.dart';

/// The widest word of a dose row's [title] and [line], in the styles of
/// `DoseRowText`.
double doseRowWord(BuildContext context, String title, String line) {
  final textTheme = Theme.of(context).textTheme;
  return longestWordOf(context, [
    (title, textTheme.rowTitle),
    (line, textTheme.bodyMedium),
  ]);
}

/// The side of the round check of a dose row in the mode of [context].
double doseCheckSide(BuildContext context) =>
    math.max(PillPalSizes.roundCheck, context.metrics.touchTarget);

/// The parts of a dose row (docs/design.md, narrow screens 7): an optional
/// [leading] status disc, the [text] and an optional [trailing] check or
/// pill on one line while the row is at least [innerFullWidth] wide (the
/// width inside the frame's padding), else the text alone on top and the
/// disc and the check together in a row under it, so no word breaks inside.
/// The rows of one card (a `CompactGroup`) switch together; [below] forces
/// the stacked layout.
///
/// It measures in a `LayoutBuilder`: not for an `IntrinsicWidth` or
/// `IntrinsicHeight` parent.
class DoseRowLayout extends StatelessWidget {
  /// Creates the layout.
  const DoseRowLayout({
    required this.text,
    required this.innerFullWidth,
    this.leading,
    this.trailing,
    this.below = false,
    super.key,
  });

  /// The name and the line under it.
  final Widget text;

  /// The narrowest width for all parts on one line.
  final double innerFullWidth;

  /// The status disc, or null.
  final Widget? leading;

  /// The round check or the status pill, or null.
  final Widget? trailing;

  /// Stacks whatever the width.
  final bool below;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = below ||
            CompactRows.of(context) ||
            constraints.maxWidth < innerFullWidth;
        return stacked ? _stacked() : _inline();
      },
    );
  }

  Widget _inline() {
    final start = leading;
    final end = trailing;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (start != null) ...[start, const Gap.h(PillPalSpacing.md)],
        Expanded(child: text),
        if (end != null) ...[const Gap.h(PillPalSpacing.md), end],
      ],
    );
  }

  Widget _stacked() {
    final start = leading;
    final end = trailing;
    if (start == null && end == null) {
      return text;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        text,
        const Gap.v(PillPalSpacing.xs),
        // A pill alone sits in the column, which bounds its width.
        if (start != null && end != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [start, const Gap.h(PillPalSpacing.md), end],
          )
        else
          start ?? end ?? const SizedBox.shrink(),
      ],
    );
  }
}
