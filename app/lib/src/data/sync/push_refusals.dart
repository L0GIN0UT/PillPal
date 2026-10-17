import '../api/sync_dto.dart';
import 'server_state_applier.dart';

/// Rejections for access reasons (ADR 0006 §6): the server's `current` is the
/// state to converge to, projected for this account's role.
const Set<String> accessRefusals = {
  'forbidden',
  'forbidden_field',
  'read_only',
};

/// Rejections that say the entity or its parent is not visible to the
/// account: in another person's scope the local copy goes (no tombstone).
const Set<String> missingRefusals = {
  'not_found',
  'parent_not_found',
  'parent_deleted',
};

/// Settles push results the server refused for access reasons. Callers run
/// this inside the transaction that handles the batch, after the refused
/// outbox entry itself was dropped.
class PushRefusals {
  /// Creates the settler over [_applier].
  PushRefusals(this._applier);

  final ServerStateApplier _applier;

  /// Converges to the server's projected `current` of a refused push.
  ///
  /// Only the refused entry is gone (ADR 0006 rule 2): pending edits of the
  /// entity's children stay and are judged by their own results. While more
  /// entries of the same entity wait, the row holds their newer edits and
  /// the last of them settles it; so `current` is applied once the entity
  /// has none left (own scopes too: the owner's refusals, e.g. a revoked
  /// guardian, end the same way). Without a `current` (a create the server
  /// refused) the local entity goes.
  Future<void> adopt(MutationResult result, String role) async {
    final current = result.current;
    if (current == null) {
      await _applier.evict(result.entity, result.id);
      return;
    }
    if (await _applier.hasPendingMutation(result.entity, result.id)) {
      return;
    }
    await _applier.apply(
      result.entity,
      result.id,
      current,
      role: role,
      overridePending: true,
    );
  }

  /// Hard-deletes the entity of a push the server says is not visible.
  Future<void> evictMissing(MutationResult result) =>
      _applier.evict(result.entity, result.id);
}
