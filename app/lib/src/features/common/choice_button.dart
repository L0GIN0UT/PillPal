import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';

/// A chip-like toggle button (mockup chips: dark when selected).
class ChoiceButton extends StatelessWidget {
  /// Creates the button.
  const ChoiceButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.selectedColor,
    super.key,
  });

  /// Text.
  final String label;

  /// Whether it is the current choice.
  final bool selected;

  /// Tap handler.
  final VoidCallback onTap;

  /// Background when selected (defaults to the ink colour).
  final Color? selectedColor;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final background = selectedColor ?? palette.ink;
    final foreground =
        selectedColor == null ? palette.background : palette.onAction;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? background : palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: PillPalRadius.chip,
          side: selected
              ? BorderSide.none
              : BorderSide(color: palette.border, width: PillPalSizes.outline),
        ),
        child: InkWell(
          borderRadius: PillPalRadius.chip,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: context.metrics.touchTarget,
              minWidth: context.metrics.touchTarget,
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: PillPalSpacing.sm,
                  vertical: PillPalSpacing.xs,
                ),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: selected ? foreground : palette.ink,
                      ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
