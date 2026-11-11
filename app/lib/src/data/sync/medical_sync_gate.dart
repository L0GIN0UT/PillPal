import '../api/consents_api.dart';
import '../api/consents_dto.dart';
import '../db/sync_state_store.dart';

/// Decides whether the sync engine may exchange medical entities with the
/// server (ADR 0016 §5). Asked once per run, before the first request.
abstract interface class MedicalSyncGate {
  /// Whether the run for [userId] may push, pull and read entities.
  /// Throws `ApiException` when it cannot be decided (offline).
  Future<bool> allows(String userId);
}

/// The consent rule: sync is paused while `health_data` is among the consents
/// the server still lacks. The stored answer decides; only when none is
/// stored (a new sign-in) it asks once with `GET /v1/me/consents`, so the same
/// code works in the background isolate, which has no screen to ask for it.
///
/// Reminders never consult it: they run from the local data.
class ConsentSyncGate implements MedicalSyncGate {
  /// Creates the gate over the stored state and the consents API.
  ConsentSyncGate({required SyncStateStore syncState, required ConsentsApi api})
      : _syncState = syncState,
        _api = api;

  final SyncStateStore _syncState;
  final ConsentsApi _api;

  @override
  Future<bool> allows(String userId) async {
    var missing = await _syncState.consentMissing();
    if (missing == null) {
      final state = await _api.get(userId: userId);
      missing = state.missing;
      await _syncState.saveConsentMissing(userId, missing);
    }
    return !missing.contains(ConsentKind.healthData.wire);
  }
}
