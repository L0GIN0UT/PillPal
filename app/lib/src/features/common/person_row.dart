import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import 'gap.dart';
import 'pillpal_card.dart';

/// The 48 circle with the first letter of a name (board B-Family). It is
/// decoration: the name beside it says who it is.
class PillPalAvatar extends StatelessWidget {
  /// Creates the avatar of [name]; a person icon while the name is empty.
  const PillPalAvatar({required this.name, super.key});

  /// The person's name.
  final String name;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final letters = name.trim().characters;
    return ExcludeSemantics(
      child: SizedBox.square(
        key: const Key('person-avatar'),
        dimension: PillPalSizes.avatarMd,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.raised,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: letters.isEmpty
                ? Icon(Icons.person_outline, color: palette.ink)
                : Text(
                    letters.first.toUpperCase(),
                    style: Theme.of(context)
                        .textTheme
                        .avatarInitial
                        .copyWith(color: palette.ink),
                  ),
          ),
        ),
      ),
    );
  }
}

/// A row of people (Family, and the invite and relative screens): a card with an avatar, the name, a line under it,
/// a status pill or a chevron at the end, and optionally an [action] icon
/// beside the tappable part. From the compact text scale on (x1.6, B2-README
/// section 9.7) the avatar and the chevron give way and the status goes under
/// the text; the whole row stays tappable.
///
/// [rowKey] sits on the tappable part (not on the action), inside the card.
class PillPalPersonRow extends StatelessWidget {
  /// Creates the row.
  const PillPalPersonRow({
    required this.rowKey,
    required this.name,
    required this.onTap,
    this.subtitle,
    this.status,
    this.action,
    this.chevron = false,
    super.key,
  });

  /// The key of the tappable part.
  final Key rowKey;

  /// The person's or profile's name.
  final String name;

  /// What is under the name (the role, for whom).
  final String? subtitle;

  /// Opens the person's page.
  final VoidCallback onTap;

  /// A status pill (icon and word), or null.
  final Widget? status;

  /// An icon button beside the row, or null.
  final Widget? action;

  /// Draws the chevron that says the row opens something.
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final end = action;
    return PillPalCard(
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          Expanded(child: _tappable(context)),
          if (end != null) ...[
            end,
            // The action's edge distance from the card: sm.
            const Gap.h(PillPalSpacing.sm),
          ],
        ],
      ),
    );
  }

  /// The name and the line under it, and the status: at the end of the line
  /// while it fits, under the text when it does not (a narrow screen) and
  /// always under it from the compact text scale on.
  Widget _body(BuildContext context, {required bool compact}) {
    final textTheme = Theme.of(context).textTheme;
    final line = subtitle;
    final pill = status;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(name, style: textTheme.rowTitleStrong),
        if (line != null) Text(line, style: textTheme.bodySmall),
        if (compact && pill != null) ...[
          const Gap.v(PillPalSpacing.xs),
          pill,
        ],
      ],
    );
    if (compact || pill == null) {
      return text;
    }
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: PillPalSpacing.md,
        runSpacing: PillPalSpacing.xs,
        children: [text, pill],
      ),
    );
  }

  Widget _tappable(BuildContext context) {
    final compact =
        MediaQuery.textScalerOf(context).scale(1) >= PillPalSizes.compactScale;
    final minHeight = context.metrics.isSenior
        ? PillPalSizes.listRowMinSenior
        : PillPalSizes.personRowMin;
    // InkWell alone marks the node focusable and tappable but not a button
    // (checked in person_row_test), so the role is stated here.
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: InkWell(
          key: rowKey,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            // heightFactor: as high as the content or the minimum, not as
            // high as the space the parent offers.
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
                    if (!compact) ...[
                      _Slot(PillPalAvatar(name: name)),
                      const Gap.h(PillPalSpacing.md),
                    ],
                    Expanded(
                      child: _Slot(
                        _body(context, compact: compact),
                        alignment: AlignmentDirectional.centerStart,
                      ),
                    ),
                    if (!compact && chevron) ...[
                      const Gap.h(PillPalSpacing.sm),
                      _Slot(
                        ExcludeSemantics(
                          child: Icon(
                            Icons.chevron_right,
                            size: PillPalSizes.iconInline,
                            color: context.palette.inkMuted,
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

/// Centres [child] on the height of the avatar; a taller child is pinned to
/// the top with the others (B2-README section 9.8).
class _Slot extends StatelessWidget {
  const _Slot(this.child, {this.alignment = AlignmentDirectional.center});

  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: PillPalSizes.avatarMd),
      child: Align(
        alignment: alignment,
        widthFactor: 1,
        heightFactor: 1,
        child: child,
      ),
    );
  }
}
