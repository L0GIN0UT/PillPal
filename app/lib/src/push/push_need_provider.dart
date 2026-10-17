import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import 'push_need.dart';

/// The registration need rule over local data and the invites API.
final pushNeedProvider = Provider<PushNeed>((ref) {
  final relatives = ref.watch(relativesApiProvider);
  return LocalPushNeed(
    db: ref.watch(databaseProvider),
    hasOpenInvite: (profileId) async =>
        (await relatives.listInvites(profileId)).isNotEmpty,
    clock: ref.watch(clockProvider),
  );
});

/// Counts the events that can change the need without touching scopes or
/// links (an invite was created or revoked). `PushScope` reconciles on each.
class PushRecheck extends Notifier<int> {
  @override
  int build() => 0;

  /// Records one such event.
  void bump() => state++;
}

/// See [PushRecheck].
final pushRecheckProvider = NotifierProvider<PushRecheck, int>(
  PushRecheck.new,
);
