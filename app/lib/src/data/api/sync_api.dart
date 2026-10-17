import '../config.dart';
import 'api_client.dart';
import 'api_exception.dart';
import 'json.dart';
import 'sync_dto.dart';

/// `POST /v1/sync/push` and `POST /v1/sync/pull` (backend/README.md, "Sync
/// protocol"; the scoped pull of docs/adr/0006-sync-scopes-and-privacy-projection.md).
class SyncApi {
  /// Creates the sync API.
  SyncApi(this._client);

  final ApiClient _client;

  /// Pushes [mutations] (at most [SyncLimits.pushBatch]); one result per
  /// mutation, in order.
  /// [userId] is the account whose data is pushed; the request is refused
  /// (`account_changed`) if the stored token belongs to another one.
  Future<List<MutationResult>> push(
    List<Mutation> mutations, {
    required String userId,
  }) async {
    if (mutations.length > SyncLimits.pushBatch) {
      throw ArgumentError.value(mutations.length, 'mutations', 'Batch too big');
    }
    final json = await _client.post(
      '/v1/sync/push',
      body: {
        'mutations': [for (final mutation in mutations) mutation.toJson()],
      },
      forUser: userId,
    );
    final reader = JsonReader(_require(json), pushResponseKeys);
    final results = [
      for (final item in reader.list('results'))
        MutationResult.fromJson(asJsonMap(item, 'result')),
    ];
    if (results.length != mutations.length) {
      throw const ApiException(ApiException.invalidResponse, 200);
    }
    return results;
  }

  /// Keys read from `PushResponse`.
  static const Set<String> pushResponseKeys = {'results'};

  /// Pulls the changes after [cursors] (profile id -> last applied `seq`;
  /// 1..[SyncLimits.pullScopes] of them). [backfillUntil] echoes the
  /// server's unfinished-backfill markers of projected scopes.
  Future<ScopedPullPage> pullScoped({
    required Map<String, int> cursors,
    required String userId,
    Map<String, int> backfillUntil = const {},
    int limit = SyncLimits.pullPage,
  }) async {
    if (cursors.isEmpty || cursors.length > SyncLimits.pullScopes) {
      throw ArgumentError.value(cursors.length, 'cursors', 'Bad group size');
    }
    final json = await _client.post(
      '/v1/sync/pull',
      body: {
        'cursors': cursors,
        'limit': limit,
        if (backfillUntil.isNotEmpty) 'backfill_until': backfillUntil,
      },
      forUser: userId,
    );
    return ScopedPullPage.fromJson(_require(json));
  }

  /// The current state (`*Out`) of a live entity, or null when the server
  /// does not have it (never created, deleted, or someone else's).
  Future<JsonMap?> fetch(
    SyncEntity entity,
    String id, {
    required String userId,
  }) async {
    final path = switch (entity) {
      SyncEntity.profile => '/v1/profiles/${Uri.encodeComponent(id)}',
      SyncEntity.medication => '/v1/medications/${Uri.encodeComponent(id)}',
      SyncEntity.schedule => '/v1/schedules/${Uri.encodeComponent(id)}',
      SyncEntity.doseEvent => '/v1/dose-events/${Uri.encodeComponent(id)}',
    };
    try {
      return _require(await _client.get(path, forUser: userId));
    } on ApiException catch (error) {
      if (error.status == 404) {
        return null;
      }
      rethrow;
    }
  }

  JsonMap _require(JsonMap? json) {
    if (json == null) {
      throw const ApiException(ApiException.invalidResponse, 200);
    }
    return json;
  }
}
