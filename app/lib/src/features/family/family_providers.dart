import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/relatives_dto.dart';
import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../../data/repositories/relatives_repository.dart';
import '../auth/auth_session.dart';
import 'family_overview.dart';
import 'profile_context.dart';

/// The stored links to relatives, oldest first.
final grantLinksProvider = StreamProvider<List<RelativeLinkRow>>(
  (ref) => ref.watch(relativesRepositoryProvider).watchLinks(),
);

/// The Family tab's three sections, from the stored links and the profiles
/// the account can see.
final familyOverviewProvider = Provider<AsyncValue<FamilyOverview>>((ref) {
  final links = ref.watch(grantLinksProvider);
  final profiles = ref.watch(accessibleProfilesProvider);
  if (links.hasError || profiles.hasError) {
    return AsyncError(
      links.error ?? profiles.error!,
      links.stackTrace ?? profiles.stackTrace ?? StackTrace.empty,
    );
  }
  final linkRows = links.valueOrNull;
  final profileRows = profiles.valueOrNull;
  if (linkRows == null || profileRows == null) {
    return const AsyncLoading();
  }
  return AsyncData(
    buildFamilyOverview(links: linkRows, profiles: profileRows),
  );
});

/// What the soft limits gate (`GET /v1/me/features`). Without an answer
/// (offline) nothing is gated: the server enforces its limits anyway.
final accountFeaturesProvider = FutureProvider<AccountFeatures>((ref) async {
  try {
    return await ref.watch(relativesApiProvider).features();
  } on ApiException {
    return const AccountFeatures();
  }
});

/// Ids of outgoing links that came back from an inactive state in this
/// session (a relative restored their account): the banner tells the owner
/// without a push (ADR 0005 §3).
final restoredRelativesProvider =
    NotifierProvider<RestoredRelatives, Set<String>>(RestoredRelatives.new);

/// The set behind [restoredRelativesProvider].
class RestoredRelatives extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  /// Adds [ids].
  void addAll(Set<String> ids) {
    if (ids.isNotEmpty) {
      state = {...state, ...ids};
    }
  }

  /// Forgets them (the owner has seen the banner).
  void clear() {
    if (state.isNotEmpty) {
      state = const <String>{};
    }
  }
}

/// Outgoing links the owner has not seen yet: accepted after the baseline,
/// or restored in this session. Inactive links are never "new".
final newRelativesProvider = Provider<List<RelativeLinkRow>>((ref) {
  final links = ref.watch(grantLinksProvider).valueOrNull ?? const [];
  final seenAt = ref.watch(_seenAtProvider).valueOrNull;
  final restored = ref.watch(restoredRelativesProvider);
  return [
    for (final link in links)
      if (link.direction == LinkDirection.outgoing &&
          link.active &&
          (restored.contains(link.id) ||
              (seenAt != null &&
                  link.createdAt > seenAt.microsecondsSinceEpoch)))
        link,
  ];
});

final _seenAtProvider = StreamProvider<DateTime?>(
  (ref) => ref.watch(relativesRepositoryProvider).watchSeenAt(),
);

/// Writes of the Family screens: links, invites, leaving, purging.
final familyActionsProvider = Provider<FamilyActions>(FamilyActions.new);

/// The use cases of the Family tab. Each write that changes what the device
/// may see also starts a sync (a revoked or left scope is evicted by the
/// next pull, ADR 0006 §7).
class FamilyActions {
  /// Creates the actions.
  FamilyActions(this._ref);

  final Ref<Object?> _ref;

  /// Re-reads the links of the account and what is gated. With [quiet] a
  /// failure keeps the stored links (offline); otherwise it is thrown.
  Future<void> refresh({bool quiet = true}) async {
    final syncState = _ref.read(syncStateStoreProvider);
    final user = await syncState.boundUserId();
    try {
      final grants =
          await _ref.read(relativesApiProvider).listGrants(forUser: user);
      // The answer belongs to the account that asked: not to one that
      // signed in meanwhile.
      if (await syncState.boundUserId() != user) {
        return;
      }
      final restored =
          await _ref.read(relativesRepositoryProvider).replaceLinks(grants);
      _ref.read(restoredRelativesProvider.notifier).addAll(restored);
    } on ApiException {
      if (!quiet) {
        rethrow;
      }
    }
    _ref.invalidate(accountFeaturesProvider);
  }

  /// The owner has looked at the Family tab: nothing is new any more.
  Future<void> markSeen() async {
    await _ref.read(relativesRepositoryProvider).markSeen();
    _ref.read(restoredRelativesProvider.notifier).clear();
  }

  /// Creates an invite for [profileId].
  ///
  /// [inviteId] is the client's UUID of this attempt: a retry after a lost
  /// response replays it and gets 409 `already_exists`. The token of that
  /// first invite is lost for good, so it is deleted (it would hold one of
  /// the few active slots for days) and a new invite is created.
  Future<InviteCreated> createInvite({
    required String profileId,
    required String inviteId,
    required String role,
    required int disclosureVersion,
  }) async {
    final api = _ref.read(relativesApiProvider);
    try {
      return await api.createInvite(
        profileId: profileId,
        inviteId: inviteId,
        role: role,
        disclosureVersion: disclosureVersion,
      );
    } on ApiException catch (error) {
      if (error.code != 'already_exists') {
        rethrow;
      }
    }
    await api.revokeInvite(profileId, inviteId);
    return api.createInvite(
      profileId: profileId,
      inviteId: _ref.read(idGeneratorProvider)(),
      role: role,
      disclosureVersion: disclosureVersion,
    );
  }

  /// Accepts the invite of [token] after the invitee confirmed it; the new
  /// scope arrives with the next pull.
  Future<IncomingGrant> acceptInvite(String token) async {
    final grant = await _ref.read(relativesApiProvider).acceptInvite(token);
    requestSyncFrom(_ref);
    await refresh();
    return grant;
  }

  /// The owner revokes link [linkId].
  Future<void> revoke(String linkId) async {
    await _delete(linkId);
    requestSyncFrom(_ref);
  }

  /// The grantee leaves the profile [profileId] they hold a grant on.
  Future<void> leaveProfile(String profileId) async {
    var link = await _incomingLink(profileId);
    if (link == null) {
      await refresh(quiet: false);
      link = await _incomingLink(profileId);
    }
    if (link != null) {
      await _delete(link.id);
    }
    requestSyncFrom(_ref);
  }

  /// The owner changes a relative's role to `viewer` or `editor` after the
  /// disclosure screen of [inviteDisclosureVersion].
  Future<void> changeRole(String linkId, String role) async {
    await _ref.read(relativesApiProvider).changeRole(
          grantId: linkId,
          role: role,
          disclosureVersion: inviteDisclosureVersion,
        );
    await _ref.read(relativesRepositoryProvider).setRole(linkId, role);
    requestSyncFrom(_ref);
  }

  /// The grantee's choice to be alerted about missed doses.
  Future<void> setNotifyMissed(String linkId, {required bool enabled}) async {
    await _ref
        .read(relativesApiProvider)
        .setNotifyMissed(linkId, enabled: enabled);
    await _ref
        .read(relativesRepositoryProvider)
        .setNotifyMissed(linkId, enabled: enabled);
  }

  /// Deletes an archive after its former owner was erased (a purge).
  Future<void> purgeArchive(String profileId) async {
    await _ref.read(relativesApiProvider).purgeProfile(profileId);
    requestSyncFrom(_ref);
  }

  Future<RelativeLinkRow?> _incomingLink(String profileId) async {
    for (final link in await _ref.read(relativesRepositoryProvider).links()) {
      if (link.direction == LinkDirection.incoming &&
          link.profileId == profileId) {
        return link;
      }
    }
    return null;
  }

  /// Deletes a grant on the server; a link that is already gone (404)
  /// counts as done.
  Future<void> _delete(String linkId) async {
    try {
      await _ref.read(relativesApiProvider).deleteGrant(linkId);
    } on ApiException catch (error) {
      if (error.status != 404) {
        rethrow;
      }
    }
    await _ref.read(relativesRepositoryProvider).forget(linkId);
  }
}
