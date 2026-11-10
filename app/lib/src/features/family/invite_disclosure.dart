import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import 'family_tiles.dart';

/// The disclosure screen text an owner confirms before inviting or changing a
/// role (docs/adr/0005 §3; its version is `inviteDisclosureVersion`): what a
/// relative will see, per privacy level, and what the role allows. Raise the
/// version whenever this text changes (a test fingerprints it).
class InviteDisclosure extends StatelessWidget {
  /// Creates the disclosure for [role] on a profile of [forSelf] kind.
  const InviteDisclosure({
    required this.role,
    required this.forSelf,
    super.key,
  });

  /// The role being granted.
  final String role;

  /// Whether the profile is the owner's own (`self`): relatives then also see
  /// its time zone and roughly when its phone last synced (D4, D5). A managed
  /// profile shows its name and time zone.
  final bool forSelf;

  /// A guardian sees everything, so its list replaces the per-level one
  /// (docs/adr/0005 §3); the others are told what each privacy level shows.
  List<String> _points(AppLocalizations l10n) {
    final identity =
        forSelf ? l10n.disclosureSelfProfile : l10n.disclosureProfileIdentity;
    if (role == ScopeRole.guardian) {
      return [
        identity,
        l10n.disclosureGuardianSees,
        l10n.disclosureGuardianCan,
        l10n.disclosureRevoke,
      ];
    }
    return [
      l10n.disclosureShared,
      l10n.disclosureAnonymous,
      l10n.disclosureHidden,
      identity,
      roleExplanation(l10n, role),
      l10n.disclosureRevoke,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final palette = context.palette;
    final title = textTheme.titleMedium?.copyWith(color: palette.onActionSoft);
    final body = textTheme.bodyMedium?.copyWith(color: palette.onActionSoft);
    final points = _points(l10n);
    // A soft card: the disclosure is part of the decision, not a warning.
    return Card(
      key: const Key('invite-disclosure'),
      color: palette.actionSoft,
      child: Padding(
        padding: PillPalSpacing.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.disclosureTitle, style: title),
            const Gap.v(PillPalSpacing.sm),
            for (final point in points)
              Padding(
                padding: const EdgeInsets.only(bottom: PillPalSpacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        top: PillPalSpacing.xs,
                        end: PillPalSpacing.sm,
                      ),
                      child: Icon(
                        Icons.check_circle_outline,
                        size: PillPalSizes.iconInline,
                        color: palette.onActionSoft,
                      ),
                    ),
                    Expanded(
                      child: Text(point, style: body),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
