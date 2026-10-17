import 'package:flutter/foundation.dart';

/// Backend connection settings, supplied with `--dart-define`.
class ApiConfig {
  /// Creates a configuration; see [ensureSecure].
  const ApiConfig({
    required this.baseUrl,
    required this.region,
    this.requestTimeout = const Duration(seconds: 30),
  });

  /// Reads `PILLPAL_API_BASE_URL` and `PILLPAL_REGION`.
  ///
  /// The default base URL is the host machine as seen from the Android
  /// emulator, which is plain http and therefore only accepted when
  /// [allowInsecure] (debug builds).
  factory ApiConfig.fromEnvironment({bool allowInsecure = kDebugMode}) {
    final config = ApiConfig(
      baseUrl: Uri.parse(
        const String.fromEnvironment(
          'PILLPAL_API_BASE_URL',
          defaultValue: 'http://10.0.2.2:8000',
        ),
      ),
      region: const String.fromEnvironment(
        'PILLPAL_REGION',
        defaultValue: 'ru',
      ),
    );
    config.ensureSecure(allowInsecure: allowInsecure);
    return config;
  }

  /// Server root, without the `/v1` prefix.
  final Uri baseUrl;

  /// Data region of the server (`ru` or `eu`), sent on registration.
  final String region;

  /// Per-request timeout.
  final Duration requestTimeout;

  /// Throws a [StateError] unless [baseUrl] uses https or [allowInsecure].
  ///
  /// Release builds never talk to the API over plain http: tokens and
  /// medical data travel in these requests.
  void ensureSecure({required bool allowInsecure}) {
    if (!allowInsecure && baseUrl.scheme != 'https') {
      throw StateError('The API base URL must use https in release builds');
    }
  }

  /// The absolute URL of API [path] (which starts with `/`).
  Uri resolve(String path, [Map<String, String>? query]) {
    final basePath = baseUrl.path.endsWith('/')
        ? baseUrl.path.substring(0, baseUrl.path.length - 1)
        : baseUrl.path;
    return baseUrl.replace(
      path: '$basePath$path',
      queryParameters: query == null || query.isEmpty ? null : query,
    );
  }
}

/// Server limits mirrored by the client (`backend/app/schemas/entities.py`,
/// `backend/app/validators.py`).
abstract final class SyncLimits {
  /// `MAX_PUSH_MUTATIONS`: mutations per push request.
  static const int pushBatch = 500;

  /// `MAX_PULL_LIMIT`: changes per pull page.
  static const int pullPage = 500;

  /// `MAX_PULL_SCOPES`: scopes (cursors) one pull request may carry.
  static const int pullScopes = 50;

  /// `ACCOUNT_DELETION_GRACE_DAYS` (default): another person's scope that
  /// has not been pulled successfully for this long is evicted from the
  /// device, because the remote wipe of a device that never syncs again is
  /// impossible (ADR 0006 §7.9).
  static const Duration staleScopeAfter = Duration(days: 30);

  /// How stale `access_scopes.last_pulled_at` may get before a pull writes
  /// it again. The staleness check works in days, and every write to the
  /// scope row wakes the streams and the re-plan, so it is not written on
  /// every page.
  static const Duration scopeTouchInterval = Duration(hours: 12);

  /// `MAX_FUTURE_SKEW`: how far ahead of the server clock a timestamp may be.
  static const Duration maxFutureSkew = Duration(minutes: 10);

  /// `MAX_SNOOZE`: `snooze_until` is at most this long after the event.
  static const Duration maxSnooze = Duration(hours: 24);
}
