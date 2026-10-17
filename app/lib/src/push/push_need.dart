import '../data/api/api_exception.dart';
import '../data/clock.dart';
import '../data/db/database.dart';
import '../data/repositories/relatives_repository.dart';

/// Whether this account needs alerts about relatives right now (ADR 0008
/// §1). A push token is registered only while it does.
abstract interface class PushNeed {
  /// True while the account needs alerts, false when it does not, and null
  /// when that cannot be told now (offline with nothing stored to go by): the
  /// registration is then left as it is.
  Future<bool?> isNeeded();

  /// An invite was created, accepted or revoked: look at the invites again.
  void invitesChanged();
}

/// The need rule over the stored scopes and links:
///
/// * an incoming grant, as viewer, editor or guardian, whose holder wants
///   missed-dose alerts (`notify_missed`);
/// * a guardian role (the scope says so even before the link list arrived);
/// * a managed profile of its own that has co-guardians (its owner is alerted
///   too, ADR 0005);
/// * an open invite (the owner is told when it is accepted, `link_accepted`).
///
/// Archives are read-only and send no alerts, so they never count. The first
/// three come from local data; open invites are asked of the server (at most
/// every [inviteCheckEvery], or after [invitesChanged]) and only when nothing
/// else already makes the answer yes.
class LocalPushNeed implements PushNeed {
  /// Creates the rule. [hasOpenInvite] asks the server whether a profile has
  /// an open invite.
  LocalPushNeed({
    required AppDatabase db,
    required Future<bool> Function(String profileId) hasOpenInvite,
    required Clock clock,
    this.inviteCheckEvery = const Duration(minutes: 30),
  })  : _db = db,
        _hasOpenInvite = hasOpenInvite,
        _clock = clock;

  /// Most owned profiles asked about invites in one check.
  static const int maxProfilesChecked = 10;

  /// How long an answer about open invites is reused.
  final Duration inviteCheckEvery;

  final AppDatabase _db;
  final Future<bool> Function(String profileId) _hasOpenInvite;
  final Clock _clock;
  DateTime? _invitesCheckedAt;
  bool _openInvite = false;

  @override
  Future<bool?> isNeeded() async {
    final scopes = await _db.select(_db.accessScopes).get();
    final links = await _db.select(_db.relativeLinks).get();
    if (_alertsFromOthers(scopes, links) || _guardedOwnProfile(scopes, links)) {
      return true;
    }
    return _hasInvite(scopes);
  }

  @override
  void invitesChanged() {
    _invitesCheckedAt = null;
  }

  /// Someone else's profile (or a managed one I guard) that alerts me.
  bool _alertsFromOthers(
    List<AccessScopeRow> scopes,
    List<RelativeLinkRow> links,
  ) {
    final incoming = {
      for (final link in links)
        if (link.direction == LinkDirection.incoming) link.profileId: link,
    };
    for (final scope in scopes) {
      if (scope.archived || scope.role == ScopeRole.owner) {
        continue;
      }
      final link = incoming[scope.profileId];
      if (link == null || link.notifyMissed) {
        return true;
      }
    }
    // A grant accepted a moment ago: its scope arrives with the next pull.
    final known = {for (final scope in scopes) scope.profileId};
    return incoming.values.any(
      (link) => link.notifyMissed && !known.contains(link.profileId),
    );
  }

  /// A managed profile I own with at least one active co-guardian.
  bool _guardedOwnProfile(
    List<AccessScopeRow> scopes,
    List<RelativeLinkRow> links,
  ) {
    final guarded = {
      for (final link in links)
        if (link.direction == LinkDirection.outgoing &&
            link.active &&
            link.role == ScopeRole.guardian)
          link.profileId,
    };
    return scopes.any(
      (scope) =>
          scope.role == ScopeRole.owner &&
          scope.kind == 'managed' &&
          !scope.archived &&
          guarded.contains(scope.profileId),
    );
  }

  Future<bool?> _hasInvite(List<AccessScopeRow> scopes) async {
    final checkedAt = _invitesCheckedAt;
    if (checkedAt != null &&
        _clock().difference(checkedAt) < inviteCheckEvery) {
      return _openInvite;
    }
    final owned = [
      for (final scope in scopes)
        if (scope.role == ScopeRole.owner && !scope.archived) scope.profileId,
    ].take(maxProfilesChecked).toList();
    if (owned.isEmpty) {
      return false; // no scope yet: asked again once the first pull is in
    }
    try {
      var open = false;
      for (final profileId in owned) {
        if (await _hasOpenInvite(profileId)) {
          open = true;
          break;
        }
      }
      _openInvite = open;
      _invitesCheckedAt = _clock();
      return open;
    } on ApiException {
      return null;
    }
  }
}
