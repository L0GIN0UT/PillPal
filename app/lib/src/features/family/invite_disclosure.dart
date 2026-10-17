import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import 'family_tiles.dart';

/// The disclosure screen text an owner confirms before inviting or changing a
/// role (docs/adr/0005 §3; its version is `inviteDisclosureVersion`): what a
/// relative will see, per privacy level, and what the role allows. Raise the
/// version whenever this text changes.
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
  /// its time zone and roughly when its phone last synced (D4, D5).
  final bool forSelf;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final points = [
      l10n.disclosureShared,
      l10n.disclosureAnonymous,
      l10n.disclosureHidden,
      if (forSelf) l10n.disclosureSelfProfile,
      roleExplanation(l10n, role),
      if (role == ScopeRole.guardian) l10n.disclosureGuardian,
      l10n.disclosureRevoke,
    ];
    return Column(
      key: const Key('invite-disclosure'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.disclosureTitle, style: textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final point in points)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2, right: 8),
                  child: Icon(Icons.check_circle_outline, size: 20),
                ),
                Expanded(child: Text(point, style: textTheme.bodyMedium)),
              ],
            ),
          ),
      ],
    );
  }
}
