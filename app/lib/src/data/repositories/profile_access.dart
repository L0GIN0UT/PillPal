import 'package:flutter/foundation.dart';

import '../db/database.dart';

/// What the signed-in account may do on one profile: the profile row, the
/// caller's role on it (docs/adr/0005 §2) and the archive state, with the
/// capabilities derived from them in one place.
///
/// The UI never decides on its own which buttons exist: it asks this class,
/// so the matrix of ADR 0005 and decision D3 (editors neither mark doses nor
/// delete) is written once. The server enforces the same rules.
@immutable
class ProfileAccess {
  /// Creates the access description.
  const ProfileAccess({
    required this.profile,
    required this.role,
    this.archived = false,
    this.archivePurgeAfter,
    this.ownerLastSeenAt,
  });

  /// Builds it from a stored profile and its scope row.
  factory ProfileAccess.of(ProfileRow profile, AccessScopeRow scope) {
    return ProfileAccess(
      profile: profile,
      role: scope.role,
      archived: scope.archived,
      archivePurgeAfter: scope.archivePurgeAfter == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(
              scope.archivePurgeAfter!,
              isUtc: true,
            ),
      ownerLastSeenAt: scope.ownerLastSeenAt == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(
              scope.ownerLastSeenAt!,
              isUtc: true,
            ),
    );
  }

  /// The profile.
  final ProfileRow profile;

  /// `owner`, `guardian`, `editor` or `viewer` (`ScopeRole`).
  final String role;

  /// A read-only archive of a managed profile (D1).
  final bool archived;

  /// When an archive of an erased owner is purged; null while the owner may
  /// still restore (and for live profiles).
  final DateTime? archivePurgeAfter;

  /// When the owner's devices last synced, to the hour; foreign `self`
  /// profiles only (D5).
  final DateTime? ownerLastSeenAt;

  /// Profile id.
  String get id => profile.id;

  /// `self` or `managed`.
  bool get isManaged => profile.kind == 'managed';

  /// Whether this is the account's own `self` profile.
  bool get isOwnSelf => ScopeRole.isOwnSelf(profile.kind, role);

  /// Owner or guardian: sees everything, `hidden` medications included.
  bool get hasFullAccess => ScopeRole.hasFullAccess(role);

  /// Editor or viewer: sees the server's privacy projection.
  bool get isProjected => ScopeRole.isProjected(role);

  /// Whether the account owns the profile.
  bool get isOwner => role == ScopeRole.owner;

  /// Marking doses: owner and guardian, never on an archive (D3: editors
  /// and viewers do not mark).
  bool get canMarkDoses => hasFullAccess && !archived;

  /// Creating and changing medications and schedules (editors: `shared`
  /// ones only, see [canEditMedication]).
  bool get canEditMedications =>
      !archived && (hasFullAccess || role == ScopeRole.editor);

  /// Whether the medication [privacy] (with [redacted]) can be edited:
  /// editors never touch `anonymous` or `hidden` ones.
  bool canEditMedication({required String privacy, required bool redacted}) {
    if (!canEditMedications) {
      return false;
    }
    return hasFullAccess || (privacy == 'shared' && !redacted);
  }

  /// Deleting medications and schedules, finishing is an edit.
  bool get canDelete => hasFullAccess && !archived;

  /// Changing a medication's privacy level.
  bool get canChangePrivacy => hasFullAccess && !archived;

  /// Editing the profile and its alert settings.
  bool get canEditProfile => hasFullAccess && !archived;

  /// Inviting and revoking: the owner of a live profile.
  bool get canManageLinks => isOwner && !archived;

  /// Whether the account may give up its access (everyone but the owner).
  bool get canLeave => !isOwner;

  /// Whether the profile's reminders may fire on this device: owner and
  /// guardian, never on an archive.
  bool get mayRemind => hasFullAccess && !archived;

  /// The zone this profile's `local` medications are read in: the device
  /// zone for the account's own `self` profile, the profile's own zone for
  /// every other one (D4). The reminder planner uses the same rule.
  String localZone(String deviceZone) =>
      isOwnSelf ? deviceZone : profile.timezone;

  /// Deleting an archive is allowed after the former owner is erased.
  bool get canPurgeArchive =>
      archived && archivePurgeAfter != null && hasFullAccess;

  @override
  bool operator ==(Object other) =>
      other is ProfileAccess &&
      other.profile == profile &&
      other.role == role &&
      other.archived == archived &&
      other.archivePurgeAfter == archivePurgeAfter &&
      other.ownerLastSeenAt == ownerLastSeenAt;

  @override
  int get hashCode => Object.hash(
        profile,
        role,
        archived,
        archivePurgeAfter,
        ownerLastSeenAt,
      );
}
