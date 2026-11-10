import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// An [IconButton] whose touch target follows the mode (44, 64 in senior
/// mode; docs/design.md), so small icon buttons are not smaller than the
/// rest of the controls.
class PillPalIconButton extends StatelessWidget {
  /// Creates the button; [tooltip] is also the accessibility label.
  const PillPalIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  /// The icon.
  final IconData icon;

  /// Tooltip and semantic label.
  final String tooltip;

  /// Tap handler; null disables the button.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final target = context.metrics.touchTarget;
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon),
      onPressed: onPressed,
      constraints: BoxConstraints(minWidth: target, minHeight: target),
    );
  }
}
