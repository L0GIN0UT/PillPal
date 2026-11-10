import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import 'gap.dart';

/// Buttons one under another, each as wide as the column (B2-README sections
/// 8 and 9.6): a pair never shares a row, so a long Russian label wraps inside
/// its button instead of squeezing its neighbour. From the compact text scale
/// on, each button is at least 56 high (64 in senior mode) and grows with its
/// wrapped label.
///
/// The [children] are the buttons themselves, in order; the caller keeps their
/// keys and handlers. A destructive dialog puts the destructive one first.
class StackedButtons extends StatelessWidget {
  /// Creates the column of buttons.
  const StackedButtons({required this.children, super.key});

  /// The buttons, top to bottom.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.textScalerOf(context).scale(1) >=
        PillPalSizes.compactRowScale;
    final minHeight = compact
        ? math.max(PillPalSizes.stackedButtonMin, context.metrics.touchTarget)
        : 0.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Gap.v(PillPalSpacing.md),
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: children[i],
          ),
        ],
      ],
    );
  }
}
