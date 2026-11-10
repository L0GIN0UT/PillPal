import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';

/// The quick-take button of an upcoming dose: a 48 circle (64 in senior
/// mode) with a 2 px `outline` ring and a muted check, filled `action` while
/// pressed (B2-README `roundCheck`, Q6 of docs/redesign-plan.md).
///
/// [label] is what screen readers say, for example "Mark Magnesium as
/// taken". The caller gives [key] `dose-take-<occurrence>`; the key stays on
/// the button itself, so a tap on it takes the dose.
class RoundCheckButton extends StatefulWidget {
  /// Creates the button.
  const RoundCheckButton({
    required this.label,
    required this.onPressed,
    super.key,
  });

  /// Spoken name of the action.
  final String label;

  /// Called when the button is tapped.
  final VoidCallback onPressed;

  @override
  State<RoundCheckButton> createState() => _RoundCheckButtonState();
}

class _RoundCheckButtonState extends State<RoundCheckButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) {
      setState(() => _pressed = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final metrics = context.metrics;
    final size = math.max(PillPalSizes.roundCheck, metrics.touchTarget);
    return Semantics(
      label: widget.label,
      button: true,
      onTap: widget.onPressed,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: Material(
          color: _pressed ? palette.action : Colors.transparent,
          shape: CircleBorder(
            side: BorderSide(
              color: palette.outline,
              width: PillPalSizes.outline,
            ),
          ),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: widget.onPressed,
            onTapDown: (_) => _setPressed(true),
            onTapUp: (_) => _setPressed(false),
            onTapCancel: () => _setPressed(false),
            child: Icon(
              Icons.check,
              size: metrics.isSenior
                  ? PillPalSizes.iconSenior
                  : PillPalSizes.iconInline,
              color: _pressed ? palette.onAction : palette.inkMuted,
            ),
          ),
        ),
      ),
    );
  }
}
