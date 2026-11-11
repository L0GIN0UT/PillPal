import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import 'gap.dart';
import 'status_kind.dart';

/// The status of a dose as a pill: an icon and a word, 28 high at the normal
/// text scale and growing with the text (B2-README `statusPill`, sections 8
/// and 9.8). The meaning never rests on colour alone.
///
/// [label] replaces the word when the row says more, such as «Принято в
/// 08:05»; the icon stays. Give [key] to the pill itself (`dose-status-*`).
class StatusPill extends StatelessWidget {
  /// Creates a pill of [kind].
  const StatusPill(this.kind, {this.label, super.key});

  /// Which status.
  final StatusKind kind;

  /// Text instead of the word of the status.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final style = statusStyle(kind, context.palette);
    final word = label ?? statusWord(AppLocalizations.of(context), kind);
    final outline = style.outline;
    final textStyle = Theme.of(context)
        .textTheme
        .labelMedium
        ?.copyWith(color: style.foreground);
    // The icon sits level with the first line of text: at the top when the
    // word wraps (section 9.8), centred on that line.
    final firstLine =
        MediaQuery.textScalerOf(context).scale(textStyle?.fontSize ?? 0) *
            (textStyle?.height ?? 1);
    final iconTop = math.max(0.0, (firstLine - PillPalSizes.statusIcon) / 2);
    return Semantics(
      container: true,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: style.background,
          shape: StadiumBorder(
            side: outline == null
                ? BorderSide.none
                : BorderSide(color: outline, width: PillPalSizes.fieldBorder),
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: PillPalSizes.statusPill),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PillPalSpacing.md,
              vertical: PillPalSpacing.xs,
            ),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: iconTop),
                    child: ExcludeSemantics(
                      child: Icon(
                        style.icon,
                        size: PillPalSizes.statusIcon,
                        color: style.foreground,
                      ),
                    ),
                  ),
                  const Gap.h(PillPalSpacing.xs),
                  Flexible(child: Text(word, style: textStyle)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
