import 'package:material_ui/material_ui.dart';

import '../../theme/spacing.dart';
import 'gap.dart';

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
        // The icon grows with the text scale, like the text beside it.
        Icon(
          icon,
          size: MediaQuery.textScalerOf(context).scale(
            style?.fontSize ?? kDefaultFontSize,
          ),
          color: style?.color,
        ),
        const Gap.h(PillPalSpacing.xs),
        Expanded(child: Text(text, style: style)),
      ],
    );
  }
}
