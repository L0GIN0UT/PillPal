import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import 'gap.dart';

/// A row of a list or a settings group (B2-README `listRow`): a 40 tile with
/// an icon, a [title] with an optional [subtitle], a [trailing] value and a
/// chevron. At least 60 high, 76 in senior mode. Put rows in a
/// `PillPalCard.rows`, which draws the hairline dividers between them.
///
/// Beside the text the trailing value sits at the top once the row grows past
/// one line (section 9.8). From the compact text scale on (section 9.7) the
/// tile and the chevron go away, the whole row stays tappable, and the
/// trailing value moves under the text, so a long value cannot squeeze the
/// title.
///
/// A [destructive] row (delete the account) is the one place a row speaks in
/// `danger`: the title and a `dangerSoft` tile.
///
/// Give [key] to the row itself; it is the tappable.
class PillPalListRow extends StatelessWidget {
  /// Creates a row. [showChevron] defaults to whether the row is tappable.
  const PillPalListRow({
    required this.title,
    this.subtitle,
    this.leadingIcon,
    this.trailing,
    this.onTap,
    this.showChevron,
    this.destructive = false,
    super.key,
  });

  /// Main text.
  final String title;

  /// Second line, muted.
  final String? subtitle;

  /// Icon of the tile; no tile when null.
  final IconData? leadingIcon;

  /// A value or control at the end, such as the current choice.
  final Widget? trailing;

  /// Called when the row is tapped; null makes a plain row.
  final VoidCallback? onTap;

  /// Whether to draw the chevron; true when [onTap] is set, by default.
  final bool? showChevron;

  /// Whether the row deletes something for good: danger title and tile.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.textScalerOf(context).scale(1) >= PillPalSizes.compactScale;
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final icon = leadingIcon;
    final end = trailing;
    final minHeight = context.metrics.isSenior
        ? PillPalSizes.listRowMinSenior
        : PillPalSizes.listRowMin;
    final line = subtitle;
    final chevron = (showChevron ?? onTap != null) && !compact;
    return MergeSemantics(
      child: Semantics(
        button: onTap != null,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            // heightFactor: as high as the content or the minimum, not as high
            // as the space the parent offers.
            child: Center(
              heightFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: PillPalSpacing.lg,
                  vertical: PillPalSpacing.sm,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (icon != null && !compact) ...[
                      _Tile(icon, destructive: destructive),
                      const Gap.h(PillPalSpacing.md),
                    ],
                    Expanded(
                      child: _FirstLineCentred(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: destructive
                                  ? textTheme.rowTitle
                                      .copyWith(color: palette.danger)
                                  : textTheme.rowTitle,
                            ),
                            if (line != null)
                              Text(line, style: textTheme.bodySmall),
                            // A long value under the text, not beside it where
                            // it would squeeze the title to a few letters.
                            if (end != null && compact) end,
                          ],
                        ),
                        alignment: AlignmentDirectional.centerStart,
                      ),
                    ),
                    if (end != null && !compact) ...[
                      const Gap.h(PillPalSpacing.md),
                      _FirstLineCentred(end),
                    ],
                    if (chevron) ...[
                      const Gap.h(PillPalSpacing.sm),
                      _FirstLineCentred(
                        ExcludeSemantics(
                          child: Icon(
                            Icons.chevron_right,
                            size: PillPalSizes.iconInline,
                            color: palette.inkMuted,
                          ),
                        ),
                      ),
                    ],
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

/// The 40 disc with the icon of a row.
class _Tile extends StatelessWidget {
  const _Tile(this.icon, {required this.destructive});

  final IconData icon;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: destructive ? palette.dangerSoft : palette.raised,
        shape: const CircleBorder(),
      ),
      child: SizedBox.square(
        dimension: PillPalSizes.avatarSm,
        child: ExcludeSemantics(
          child: Icon(
            icon,
            size: PillPalSizes.iconInline,
            color: destructive ? palette.onDangerSoft : palette.ink,
          ),
        ),
      ),
    );
  }
}

/// Centres [child] in a box as high as the tile: a one-line row looks
/// centred, while a taller one keeps [child] at its top (section 9.8).
class _FirstLineCentred extends StatelessWidget {
  const _FirstLineCentred(
    this.child, {
    this.alignment = AlignmentDirectional.center,
  });

  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: PillPalSizes.avatarSm),
      child: Align(
        alignment: alignment,
        widthFactor: 1,
        heightFactor: 1,
        child: child,
      ),
    );
  }
}
