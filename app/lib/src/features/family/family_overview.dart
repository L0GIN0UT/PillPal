import '../../data/db/database.dart';
import '../../data/repositories/profile_access.dart';
import '../../data/repositories/relatives_repository.dart';
import 'relatives_list.dart';

export 'relatives_list.dart';

/// Version of the disclosure screen an owner confirms before inviting or
/// changing a role (sent as `disclosure_version`, copied to the grant;
/// ADR 0005 §3). Raise it whenever the disclosed text changes.
const int inviteDisclosureVersion = 1;

/// What the Family tab lists: one row per relative (docs/adr/0020 §4).
class FamilyOverview {
  /// Creates an overview.
  const FamilyOverview({required this.relatives, this.activeRelatives = 0});

  /// «Близкие»: people and managed profiles, inactive links and archives
  /// included (an account in its deletion grace period gives no access but
  /// the owner may still revoke the grant).
  final List<Relative> relatives;

  /// Active grants on the account's own profiles: what the relatives limit
  /// of the soft limits counts.
  final int activeRelatives;

  /// Whether nobody is listed.
  bool get isEmpty => relatives.isEmpty;

  /// The row of [key], or null.
  Relative? byKey(String key) {
    for (final relative in relatives) {
      if (relative.key == key) {
        return relative;
      }
    }
    return null;
  }

  /// The row holding link [linkId], or null.
  Relative? byLink(String linkId) {
    for (final relative in relatives) {
      if (relative.incoming?.id == linkId ||
          relative.outgoing.any((link) => link.id == linkId)) {
        return relative;
      }
    }
    return null;
  }
}

/// The Family tab of [links], [profiles] and [notes] (pure).
FamilyOverview buildFamilyOverview({
  required List<RelativeLinkRow> links,
  required List<ProfileAccess> profiles,
  Map<String, String> notes = const {},
}) {
  return FamilyOverview(
    relatives: buildRelatives(links: links, profiles: profiles, notes: notes),
    activeRelatives: links
        .where(
          (link) => link.direction == LinkDirection.outgoing && link.active,
        )
        .length,
  );
}
