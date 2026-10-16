import 'package:flutter/material.dart';

import '../../theme/palette.dart';

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
          borderRadius: BorderRadius.circular(14),
          side: selected
              ? BorderSide.none
              : BorderSide(color: palette.border, width: 2),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
