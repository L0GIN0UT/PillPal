import '../api/api_exception.dart';
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
/// the server still lacks. Every run asks `GET /v1/me/consents` and stores
/// the answer, so a stale one (consents given or a version bumped elsewhere)
/// never decides while the network is up. The stored answer is used only
/// when the server cannot be reached - then nothing would be sent anyway - and
/// if there is none, the run fails with the network error. The same code
/// works in the background isolate, which has no screen to ask for it.
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
    final List<String> missing;
    try {
      missing = (await _api.get(userId: userId)).missing;
      await _syncState.saveConsentMissing(userId, missing);
    } on ApiException catch (error) {
      final stored = await _syncState.consentMissing();
      if (error.code != ApiException.networkError || stored == null) {
        rethrow;
      }
      return !stored.contains(ConsentKind.healthData.wire);
    }
    return !missing.contains(ConsentKind.healthData.wire);
  }
}
