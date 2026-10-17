import '../../data/db/database.dart';
import '../../data/repositories/profile_access.dart';
import '../../data/repositories/relatives_repository.dart';

/// What becomes of a managed profile when its owner's account is erased
/// (docs/adr/0010 §4, decision D1).
class ManagedProfileFate {
  /// Creates the fate of the profile named [name].
  const ManagedProfileFate({required this.name, required this.archived});

  /// The profile's display name.
  final String name;

  /// Whether an active co-guardian takes it over as a read-only archive;
  /// otherwise it is erased with the account.
  final bool archived;
}

/// The fate of each live managed profile the account owns (pure).
///
/// A co-guardian counts only while their grant is active: the server hands
/// the profile to the earliest *active* one. Archives, profiles of other
/// people and the account's own `self` profile are not listed.
List<ManagedProfileFate> managedProfileFates({
  required List<ProfileAccess> profiles,
  required List<RelativeLinkRow> links,
}) {
  bool hasCoGuardian(String profileId) => links.any(
        (link) =>
            link.direction == LinkDirection.outgoing &&
            link.profileId == profileId &&
            link.role == ScopeRole.guardian &&
            link.active,
      );
  return [
    for (final access in profiles)
      if (access.isManaged && access.isOwner && !access.archived)
        ManagedProfileFate(
          name: access.profile.displayName,
          archived: hasCoGuardian(access.id),
        ),
  ];
}
