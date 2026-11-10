import 'package:flutter/material.dart';

import '../../theme/spacing.dart';

/// A small icon with a wrapping text, for labels that must not rely on
/// colour alone (docs/design.md).
class IconLabel extends StatelessWidget {
  /// Creates the label.
  const IconLabel({required this.icon, required this.text, super.key});

  /// Leading icon.
  final IconData icon;

  /// The text.
  final String text;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: style?.fontSize, color: style?.color),
        const SizedBox(width: PillPalSpacing.xs),
        Expanded(child: Text(text, style: style)),
      ],
    );
  }
}
