import 'package:flutter/foundation.dart';

import '../../data/db/database.dart';
import '../../data/repositories/profile_access.dart';
import '../../data/repositories/relatives_repository.dart';

// The one list «Близкие» (relatives redesign, docs/adr/0020 §4): one row per
// person or managed profile, whatever links tie the account to them. Pure:
// the widgets localize the role kinds.

/// What a relative is to the account, one per link or managed profile.
enum RelativeRoleKind {
  /// I see their medications (incoming viewer): «подопечный».
  ward,

  /// I see and may change them (incoming editor): «подопечный · могу
  /// менять».
  wardEditor,

  /// They see mine (outgoing viewer): «наблюдатель».
  observer,

  /// They see and may change mine (outgoing editor): «помощник».
  helper,

  /// They are a guardian of one of my managed profiles: «опекун · {name}».
  guardian,

  /// My own managed profile: «веду сам».
  managedByMe,

  /// I am a guardian of someone else's managed profile: «веду вместе с
  /// {owner}».
  coGuardian,
}

/// One role of a relative.
@immutable
class RelativeRole {
  /// Creates a role.
  const RelativeRole(
    this.kind, {
    this.profileName,
    this.ownerName,
    this.active = true,
  });

  /// What the role is.
  final RelativeRoleKind kind;

  /// The managed profile of mine an outgoing link is on, or null for my
  /// own self profile.
  final String? profileName;

  /// The owner of a managed profile I co-guard, when the server names them.
  final String? ownerName;

  /// False while the link gives no access (an account in its deletion
  /// grace period).
  final bool active;

  @override
  bool operator ==(Object other) =>
      other is RelativeRole &&
      other.kind == kind &&
      other.profileName == profileName &&
      other.ownerName == ownerName &&
      other.active == active;

  @override
  int get hashCode => Object.hash(kind, profileName, ownerName, active);

  @override
  String toString() => 'RelativeRole($kind, active: $active)';
}

/// "{note} ({name})" when there is a note, else the name.
String relativeTitle({required String name, String? note}) =>
    note == null ? name : '$note ($name)';

/// A row of «Близкие»: a person (their self profile) or a managed profile.
@immutable
class Relative {
  /// Creates a row.
  const Relative({
    required this.key,
    required this.name,
    required this.roles,
    this.subjectProfileId,
    this.note,
    this.incoming,
    this.outgoing = const [],
    this.access,
  });

  /// Stable id of the row and of its card route: the subject profile id,
  /// or the link id when the server does not name the relative's profile.
  final String key;

  /// The profile that stands for the relative (their self profile or a
  /// managed profile): the key of the private note; null when unknown.
  final String? subjectProfileId;

  /// The person's or profile's name; empty when the server tells none.
  final String name;

  /// The account's private note about them, if any. Never logged.
  final String? note;

  /// Every role, in a stable order: managed, incoming, outgoing.
  final List<RelativeRole> roles;

  /// My link on their profile (I see them), if any.
  final RelativeLinkRow? incoming;

  /// Their links on my profiles (they see me), oldest first.
  final List<RelativeLinkRow> outgoing;

  /// A managed profile I own or guard, if this row is one.
  final ProfileAccess? access;

  /// The profile whose day the row opens, or null when I see no data.
  String? get dayProfileId => incoming?.profileId ?? access?.id;

  /// Whether a private note can be kept about them: only while a link
  /// relates us (my own managed profile is not a relationship).
  bool get canHaveNote =>
      subjectProfileId != null && (incoming != null || outgoing.isNotEmpty);

  /// Whether nothing gives access now: only paused outgoing links.
  bool get inactive =>
      incoming == null &&
      access == null &&
      outgoing.isNotEmpty &&
      outgoing.every((link) => !link.active);

  /// A read-only archive of a managed profile.
  bool get archived => access?.archived ?? false;

  @override
  bool operator ==(Object other) =>
      other is Relative &&
      other.key == key &&
      other.subjectProfileId == subjectProfileId &&
      other.name == name &&
      other.note == note &&
      listEquals(other.roles, roles) &&
      other.incoming == incoming &&
      listEquals(other.outgoing, outgoing) &&
      other.access == access;

  @override
  int get hashCode => Object.hash(
        key,
        subjectProfileId,
        name,
        note,
        Object.hashAll(roles),
        incoming,
        Object.hashAll(outgoing),
        access,
      );

  // No note or name here: they are personal data and may carry health
  // context.
  @override
  String toString() => 'Relative($key, $roles)';
}

/// Merges [links] and the managed profiles of [profiles] into one row per
/// person or profile, with the account's [notes] (by subject profile id).
/// A person related both ways is one row with both roles. Order: managed
/// profiles, then the people I see, then those who only see me.
List<Relative> buildRelatives({
  required List<RelativeLinkRow> links,
  required List<ProfileAccess> profiles,
  Map<String, String> notes = const {},
}) {
  final rows = <String, _RelativeDraft>{};
  _RelativeDraft at(String key) =>
      rows.putIfAbsent(key, () => _RelativeDraft(key));
  for (final access in profiles) {
    if (access.isManaged && access.hasFullAccess) {
      at(access.id).access = access;
    }
  }
  for (final link in links) {
    if (link.direction == LinkDirection.incoming) {
      final subject = link.counterpartProfileId ?? link.profileId;
      at(subject)
        ..subject = subject
        ..incoming = link;
    }
  }
  for (final link in links) {
    if (link.direction == LinkDirection.outgoing) {
      final subject = link.counterpartProfileId;
      final draft = at(subject ?? link.id)..outgoing.add(link);
      if (subject != null) {
        draft.subject = subject;
      }
    }
  }
  return [for (final draft in rows.values) draft.build(notes)];
}

class _RelativeDraft {
  _RelativeDraft(this.key);

  final String key;
  String? subject;
  RelativeLinkRow? incoming;
  final List<RelativeLinkRow> outgoing = [];
  ProfileAccess? access;

  Relative build(Map<String, String> notes) {
    final subjectId = subject ?? access?.id;
    // The same rule as [Relative.canHaveNote]: a note only while related.
    final related =
        subjectId != null && (incoming != null || outgoing.isNotEmpty);
    return Relative(
      key: key,
      subjectProfileId: subjectId,
      name: _name(),
      note: related ? notes[subjectId] : null,
      roles: _roles(),
      incoming: incoming,
      outgoing: List.unmodifiable(outgoing),
      access: access,
    );
  }

  String _name() {
    final candidates = [
      incoming?.profileName,
      access?.profile.displayName,
      for (final link in outgoing) link.counterpartName,
      incoming?.counterpartName,
    ];
    for (final name in candidates) {
      if (name != null && name.trim().isNotEmpty) {
        return name;
      }
    }
    return '';
  }

  List<RelativeRole> _roles() {
    final link = incoming;
    final managed = access;
    return [
      if (managed != null && managed.isOwner)
        const RelativeRole(RelativeRoleKind.managedByMe),
      if (link != null)
        _incomingRole(link)
      else if (managed != null && !managed.isOwner)
        const RelativeRole(RelativeRoleKind.coGuardian),
      for (final grant in outgoing) _outgoingRole(grant),
    ];
  }

  static RelativeRole _incomingRole(RelativeLinkRow link) {
    switch (link.role) {
      case ScopeRole.guardian:
        return RelativeRole(
          RelativeRoleKind.coGuardian,
          ownerName: link.counterpartName,
        );
      case ScopeRole.editor:
        return const RelativeRole(RelativeRoleKind.wardEditor);
      default:
        return const RelativeRole(RelativeRoleKind.ward);
    }
  }

  static RelativeRole _outgoingRole(RelativeLinkRow link) {
    final kind = switch (link.role) {
      ScopeRole.guardian => RelativeRoleKind.guardian,
      ScopeRole.editor => RelativeRoleKind.helper,
      _ => RelativeRoleKind.observer,
    };
    final managed =
        link.profileKind == 'managed' && link.profileName.isNotEmpty;
    return RelativeRole(
      kind,
      profileName: managed ? link.profileName : null,
      active: link.active,
    );
  }
}
