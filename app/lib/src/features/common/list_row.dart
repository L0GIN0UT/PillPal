import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import 'compact_rows.dart';
import 'compact_text.dart';
import 'gap.dart';
import 'text_fit.dart';

/// A row of a list or a settings group (B2-README `listRow`): a 40 tile with
/// an icon, a [title] with an optional [subtitle], a [trailing] value and a
/// chevron. At least 60 high, 76 in senior mode. Put rows in a
/// `PillPalCard.rows`, which draws the hairline dividers between them.
///
/// Beside the text the trailing value sits at the top once the row grows past
/// one line (section 9.8). From the compact text scale on (section 9.7), and
/// on a screen too narrow for a word of the text beside them, the tile and
/// the chevron go away, the whole row stays tappable, and the trailing value
/// moves under the text, so nothing squeezes the title to a few letters.
///
/// [destructive] is for destructive rows only (delete the account): the
/// title in `danger` (text-safe on `surface` in all four palettes, see
/// `theme_contrast_test`) and a `dangerSoft` tile.
///
/// In a `PillPalCard.rows` (a `CompactGroup`) every row takes the narrow
/// layout when one of them needs it, so the rows of a card look the same.
/// The row measures in a `LayoutBuilder`: not for an `IntrinsicWidth` or
/// `IntrinsicHeight` parent.
///
/// Give [key] to the row itself; it is the tappable.
class PillPalListRow extends StatelessWidget implements NarrowAware {
  /// Creates a row. [showChevron] defaults to whether the row is tappable.
  const PillPalListRow({
    required this.title,
    this.subtitle,
    this.leadingIcon,
    this.trailing,
    this.onTap,
    this.showChevron,
    this.destructive = false,
    this.trailingIsControl = false,
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

  /// Whether [trailing] is a control of its own (a ⋮ menu): it then stays a
  /// separate semantics node instead of merging into the row's label.
  final bool trailingIsControl;

  @override
  double fullLayoutWidth(BuildContext context) =>
      _innerFullWidth(context) +
      (trailingIsControl && trailing != null
          ? context.metrics.touchTarget + PillPalSpacing.sm
          : 0.0);

  @override
  Widget build(BuildContext context) {
    // A control is drawn beside the row, outside its merged semantics.
    final control = trailingIsControl ? trailing : null;
    // Measured once; the layout below only compares widths.
    final full = _innerFullWidth(context);
    final row = LayoutBuilder(
      builder: (context, constraints) => _row(
        context,
        compact: isCompactText(context) ||
            CompactRows.of(context) ||
            constraints.maxWidth < full,
      ),
    );
    if (control == null) {
      return row;
    }
    return Row(
      children: [
        Expanded(child: row),
        Padding(
          padding: const EdgeInsetsDirectional.only(end: PillPalSpacing.sm),
          child: control,
        ),
      ],
    );
  }

  /// The width the row needs (without a trailing control) to keep its tile,
  /// chevron and trailing value beside the text with no word broken inside:
  /// below it the row is compact (a Galaxy Z Fold cover screen).
  double _innerFullWidth(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final line = subtitle;
    final hasEnd = trailing != null && !trailingIsControl;
    final reserved = 2 * PillPalSpacing.lg +
        (leadingIcon == null
            ? 0.0
            : PillPalSizes.avatarSm + PillPalSpacing.md) +
        ((showChevron ?? onTap != null)
            ? PillPalSpacing.sm + PillPalSizes.iconInline
            : 0.0) +
        (hasEnd ? PillPalSpacing.md + _trailingWidth(context) : 0.0);
    return reserved +
        longestWordOf(context, [
          (title, textTheme.rowTitle),
          if (line != null) (line, textTheme.bodySmall),
        ]);
  }

  /// The width of a trailing value: a text or an icon is measured; anything
  /// else is taken as a touch target wide.
  double _trailingWidth(BuildContext context) {
    final end = trailing;
    if (end is Text) {
      final data = end.data;
      if (data != null) {
        return lineWidth(context, data, end.style);
      }
    }
    if (end is Icon) {
      return end.size ?? IconTheme.of(context).size ?? PillPalSizes.iconInline;
    }
    return context.metrics.touchTarget;
  }

  Widget _row(BuildContext context, {required bool compact}) {
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final icon = leadingIcon;
    final end = trailingIsControl ? null : trailing;
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
