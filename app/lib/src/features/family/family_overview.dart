import '../../data/db/database.dart';
import '../../data/repositories/profile_access.dart';
import '../../data/repositories/relatives_repository.dart';

/// Version of the disclosure screen an owner confirms before inviting or
/// changing a role (sent as `disclosure_version`, copied to the grant;
/// ADR 0005 §3). Raise it whenever the disclosed text changes.
const int inviteDisclosureVersion = 1;

/// What the Family tab lists, in its three sections.
class FamilyOverview {
  /// Creates an overview.
  const FamilyOverview({
    required this.seeMe,
    required this.iSee,
    required this.wards,
  });

  /// "Видят меня": grants on the account's own profiles, inactive ones
  /// included (an account in its deletion grace period gives no access but
  /// the owner may still revoke the grant).
  final List<RelativeLinkRow> seeMe;

  /// "Я вижу": other people's profiles seen as viewer or editor.
  final List<RelativeLinkRow> iSee;

  /// "Подопечные": managed profiles the account owns or guards, archives
  /// included.
  final List<ProfileAccess> wards;

  /// Whether nothing is listed anywhere.
  bool get isEmpty => seeMe.isEmpty && iSee.isEmpty && wards.isEmpty;

  /// Active grants on the account's own profiles: what the relatives limit
  /// of the soft limits counts.
  int get activeRelatives => seeMe.where((link) => link.active).length;
}

/// Sorts [links] and [profiles] into the sections of the Family tab (pure).
FamilyOverview buildFamilyOverview({
  required List<RelativeLinkRow> links,
  required List<ProfileAccess> profiles,
}) {
  return FamilyOverview(
    seeMe: [
      for (final link in links)
        if (link.direction == LinkDirection.outgoing) link,
    ],
    iSee: [
      for (final link in links)
        if (link.direction == LinkDirection.incoming &&
            !ScopeRole.hasFullAccess(link.role))
          link,
    ],
    wards: [
      for (final access in profiles)
        if (access.isManaged && access.hasFullAccess) access,
    ],
  );
}
