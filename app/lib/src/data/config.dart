/// Backend connection settings, supplied with `--dart-define`.
class ApiConfig {
  /// Creates a configuration.
  const ApiConfig({
    required this.baseUrl,
    required this.region,
    this.requestTimeout = const Duration(seconds: 30),
  });

  /// Reads `PILLPAL_API_BASE_URL` and `PILLPAL_REGION`.
  ///
  /// The default base URL is the host machine as seen from the Android
  /// emulator.
  factory ApiConfig.fromEnvironment() {
    return ApiConfig(
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
  }

  /// Server root, without the `/v1` prefix.
  final Uri baseUrl;

  /// Data region of the server (`ru` or `eu`), sent on registration.
  final String region;

  /// Per-request timeout.
  final Duration requestTimeout;

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

/// Server limits mirrored by the client (`backend/app/schemas/entities.py`).
abstract final class SyncLimits {
  /// `MAX_PUSH_MUTATIONS`: mutations per push request.
  static const int pushBatch = 500;

  /// `MAX_PULL_LIMIT`: changes per pull page.
  static const int pullPage = 500;
}
