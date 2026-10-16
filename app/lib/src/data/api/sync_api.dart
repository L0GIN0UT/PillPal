import '../config.dart';
import 'api_client.dart';
import 'api_exception.dart';
import 'json.dart';
import 'sync_dto.dart';

/// `POST /v1/sync/push` and `GET /v1/sync/pull` (backend/README.md, "Sync protocol").
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

  /// Pulls the changes after [cursor].
  Future<PullPage> pull({
    required int cursor,
    required String userId,
    int limit = SyncLimits.pullPage,
  }) async {
    final json = await _client.get(
      '/v1/sync/pull',
      query: {'cursor': '$cursor', 'limit': '$limit'},
      forUser: userId,
    );
    return PullPage.fromJson(_require(json));
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
