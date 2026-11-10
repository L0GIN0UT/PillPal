import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';

/// An [IconButton] drawn as a circle of 48 (64 in senior mode, so it is the
/// touch target of the mode; docs/design.md). The [PillPalIconButton.secondary]
/// variant adds a ring of the `border` colour.
class PillPalIconButton extends StatelessWidget {
  /// Creates the button; [tooltip] is also the accessibility label.
  const PillPalIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  }) : secondary = false;

  /// A button with a `border` ring, for actions beside a header.
  const PillPalIconButton.secondary({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  }) : secondary = true;

  /// The icon.
  final IconData icon;

  /// Tooltip and semantic label.
  final String tooltip;

  /// Tap handler; null disables the button.
  final VoidCallback? onPressed;

  /// Whether the circle has a ring.
  final bool secondary;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final target = math.max(PillPalSizes.avatarMd, context.metrics.touchTarget);
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon),
      onPressed: onPressed,
      constraints: BoxConstraints.tightFor(width: target, height: target),
      style: IconButton.styleFrom(
        foregroundColor: palette.ink,
        disabledForegroundColor: palette.inkMuted,
        padding: EdgeInsets.zero,
        shape: CircleBorder(
          side: secondary
              ? BorderSide(
                  color: palette.border,
                  width: PillPalSizes.fieldBorder,
                )
              : BorderSide.none,
        ),
      ),
    );
  }
}
