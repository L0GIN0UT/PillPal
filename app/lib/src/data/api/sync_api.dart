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
  Future<List<MutationResult>> push(List<Mutation> mutations) async {
    if (mutations.length > SyncLimits.pushBatch) {
      throw ArgumentError.value(mutations.length, 'mutations', 'Batch too big');
    }
    final json = await _client.post(
      '/v1/sync/push',
      body: {
        'mutations': [for (final mutation in mutations) mutation.toJson()],
      },
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
  Future<PullPage> pull(
      {required int cursor, int limit = SyncLimits.pullPage}) async {
    final json = await _client.get(
      '/v1/sync/pull',
      query: {'cursor': '$cursor', 'limit': '$limit'},
    );
    return PullPage.fromJson(_require(json));
  }

  JsonMap _require(JsonMap? json) {
    if (json == null) {
      throw const ApiException(ApiException.invalidResponse, 200);
    }
    return json;
  }
}
