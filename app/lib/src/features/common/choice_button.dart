import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import 'gap.dart';

/// A chip-like toggle button: a stadium. Off: `surface` with a 1 px `border`.
/// Selected: `selected` with `onSelected` text and a check icon, so the
/// choice never rests on colour alone.
///
/// With a [selectedColor] (the weekday circles) the selected chip is a solid
/// disc of that colour with `onAction` text and no check: those chips are as
/// narrow as a touch target.
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

  /// Solid background when selected, instead of the soft look with a check.
  final Color? selectedColor;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final custom = selectedColor;
    final background = custom ?? palette.selected;
    final foreground = custom == null ? palette.onSelected : palette.onAction;
    final style = Theme.of(context).textTheme.labelMedium;
    final showCheck = selected && custom == null;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? background : palette.surface,
        shape: StadiumBorder(
          side: selected
              ? BorderSide.none
              : BorderSide(color: palette.border, width: PillPalSizes.hairline),
        ),
        child: InkWell(
          customBorder: PillPalRadius.pill,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: context.metrics.touchTarget,
              minWidth: context.metrics.touchTarget,
            ),
            child: Center(
              child: Padding(
                // Fixed-width discs (weekdays) keep their label on one line.
                padding: EdgeInsets.symmetric(
                  horizontal:
                      custom == null ? PillPalSpacing.md : PillPalSpacing.xs,
                  vertical: PillPalSpacing.xs,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showCheck) ...[
                      // Decorative: the selected state is in the semantics.
                      ExcludeSemantics(
                        child: Icon(
                          Icons.check,
                          color: foreground,
                          size: PillPalSizes.iconInline,
                        ),
                      ),
                      const Gap.h(PillPalSpacing.xs),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: style?.copyWith(
                          color: selected ? foreground : palette.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
