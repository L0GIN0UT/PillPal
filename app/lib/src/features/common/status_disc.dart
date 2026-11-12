import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/motion.dart';
import '../../theme/palette.dart';
import 'status_kind.dart';

/// The status of a dose as a round mark, 40 across (52 in senior mode, drawn
/// solid there): the leading element of the «Уже было» rows and of History
/// (B2-README `statusDisc`). It carries the icon; the row beside it must
/// write the word. Screen readers read the word from here.
///
/// When the kind of a disc that stays on screen changes, its fill, ring and
/// icon ease to the new colours in `base` (instant with reduced motion).
///
/// Give [key] to the disc itself (`dose-taken-*`, `dose-missed-*`).
class StatusDisc extends StatelessWidget {
  /// Creates a disc of [kind].
  const StatusDisc(this.kind, {super.key});

  /// Which status.
  final StatusKind kind;

  @override
  Widget build(BuildContext context) {
    final senior = context.metrics.isSenior;
    final style = statusStyle(kind, context.palette, solid: senior);
    final size =
        senior ? PillPalSizes.statusDiscSenior : PillPalSizes.statusDisc;
    final outline = style.outline;
    return Semantics(
      label: statusWord(AppLocalizations.of(context), kind),
      child: ExcludeSemantics(
        child: AnimatedContainer(
          duration: PillPalMotion.stateChange(context),
          curve: PillPalMotion.standard,
          width: size,
          height: size,
          decoration: ShapeDecoration(
            color: style.background,
            shape: CircleBorder(
              side: outline == null
                  ? BorderSide.none
                  : BorderSide(
                      color: outline,
                      width: senior
                          ? PillPalSizes.statusRingSenior
                          : PillPalSizes.fieldBorder,
                    ),
            ),
          ),
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: style.foreground),
            duration: PillPalMotion.stateChange(context),
            curve: PillPalMotion.standard,
            builder: (context, color, _) => Icon(
              style.icon,
              size: senior ? PillPalSizes.iconSenior : PillPalSizes.iconInline,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
