import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../../data/repositories/profile_access.dart';

export '../../data/repositories/profile_access.dart';

/// Every profile the account can see, own first (the profile switcher and
/// the Family tab read it).
final accessibleProfilesProvider = StreamProvider<List<ProfileAccess>>(
  (ref) => ref.watch(accessRepositoryProvider).watchAccessible(),
);

/// What the account may do on a profile; the key null is its own `self`
/// profile. Null while the scope is unknown (before the first pull) or gone.
final profileAccessProvider =
    StreamProvider.autoDispose.family<ProfileAccess?, String?>((ref, id) {
  return ref.watch(accessRepositoryProvider).watchAccess(id);
});

/// The scopes (profiles) of the account, for screens that only need to know
/// which ones exist.
final accessScopesProvider = StreamProvider<List<AccessScopeRow>>(
  (ref) => ref.watch(accessRepositoryProvider).watchScopes(),
);

/// The profile the Today, Medications and History tabs show; null is the
/// account's own `self` profile.
final selectedProfileIdProvider =
    NotifierProvider<SelectedProfile, String?>(SelectedProfile.new);

/// The choice of the profile switcher. A choice whose scope disappears (the
/// owner revoked it, the account left, an archive was purged) falls back to
/// the own profile.
class SelectedProfile extends Notifier<String?> {
  String? _chosen;

  @override
  String? build() {
    final scopes = ref.watch(accessScopesProvider).valueOrNull;
    final chosen = _chosen;
    if (chosen != null &&
        scopes != null &&
        !scopes.any((scope) => scope.profileId == chosen)) {
      _chosen = null;
      return null;
    }
    return chosen;
  }

  /// Shows [profileId] on the tabs (null: the own profile).
  void select(String? profileId) {
    _chosen = profileId;
    state = profileId;
  }
}
