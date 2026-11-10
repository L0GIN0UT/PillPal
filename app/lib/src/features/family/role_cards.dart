import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../common/pillpal_card.dart';
import 'family_tiles.dart';

/// The roles of an invite or of a link as radio rows in one card: the role,
/// and under it what it may do (board B2-InviteCreate). The whole row taps.
///
/// [roles] are `ScopeRole` values; the row of a role carries the key
/// `<keyPrefix>-<role>` (`invite-role-viewer`, `detail-role-editor`).
class RoleCards extends StatelessWidget {
  /// Creates the cards.
  const RoleCards({
    required this.roles,
    required this.selected,
    required this.onSelected,
    required this.keyPrefix,
    super.key,
  });

  /// The roles on offer, in display order.
  final List<String> roles;

  /// The chosen role; one of [roles].
  final String selected;

  /// Called with the role the user taps.
  final ValueChanged<String> onSelected;

  /// Start of the key of each row.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PillPalCard.rows(
      rows: [
        for (final role in roles)
          _RoleRow(
            key: ValueKey('$keyPrefix-$role'),
            title: roleLabel(l10n, role),
            hint: roleExplanation(l10n, role),
            selected: role == selected,
            onTap: () => onSelected(role),
          ),
      ],
    );
  }
}

class _RoleRow extends StatelessWidget {
  const _RoleRow({
    required this.title,
    required this.hint,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String title;
  final String hint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final minHeight = context.metrics.isSenior
        ? PillPalSizes.listRowMinSenior
        : PillPalSizes.listRowMin;
    return Semantics(
      label: '$title\n$hint',
      inMutuallyExclusiveGroup: true,
      checked: selected,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PillPalSpacing.lg,
              vertical: PillPalSpacing.sm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: PillPalSpacing.xs),
                  child: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: PillPalSizes.iconInline,
                    color: selected ? palette.action : palette.outline,
                  ),
                ),
                const Gap.h(PillPalSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: textTheme.rowTitle),
                      Text(hint, style: textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
