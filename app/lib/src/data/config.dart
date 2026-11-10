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

/// Hosts of invite links per data region, supplied with `--dart-define`
/// `PILLPAL_LINK_HOSTS` as `ru=host,eu=host` (docs/adr/0009-invite-links.md).
///
/// Until the owner picks a domain (D6) the hosts are the placeholders below
/// under the reserved `.invalid` TLD: they never resolve, so only the paste
/// fallback and explicit intents work on a real device. Android takes the
/// same hosts from Gradle `manifestPlaceholders`, iOS from `Links.xcconfig`.
class LinkConfig {
  /// Creates a configuration; [hosts] maps a region to its link host.
  const LinkConfig({required this.hosts, required this.region});

  /// The placeholder hosts of both regions.
  static const String placeholderHosts =
      'ru=links-ru.pillpal.invalid,eu=links-eu.pillpal.invalid';

  /// Parses [spec] (`ru=host,eu=host`); entries that are not `region=host`
  /// are ignored. [region] is the region this build serves.
  factory LinkConfig.parse(String spec, {required String region}) {
    final hosts = <String, String>{};
    for (final entry in spec.split(',')) {
      final parts = entry.split('=');
      if (parts.length != 2) {
        continue;
      }
      final key = parts[0].trim().toLowerCase();
      final host = parts[1].trim().toLowerCase();
      if (key.isNotEmpty && host.isNotEmpty) {
        hosts[key] = host;
      }
    }
    return LinkConfig(hosts: hosts, region: region);
  }

  /// Reads `PILLPAL_LINK_HOSTS` for [region] (`PILLPAL_REGION`).
  factory LinkConfig.fromEnvironment({required String region}) {
    return LinkConfig.parse(
      const String.fromEnvironment(
        'PILLPAL_LINK_HOSTS',
        defaultValue: placeholderHosts,
      ),
      region: region,
    );
  }

  /// Link host of each region.
  final Map<String, String> hosts;

  /// The region this build serves.
  final String region;

  /// The region whose links use [host] (compared case-insensitively), or
  /// null for a host this app does not know.
  String? regionOfHost(String host) {
    final wanted = host.toLowerCase();
    for (final entry in hosts.entries) {
      if (entry.value == wanted) {
        return entry.key;
      }
    }
    return null;
  }
}

/// Where the global catalog service of this build's region lives, supplied
/// with `--dart-define` `PILLPAL_CATALOG_URLS` as `ru=https://...,eu=...`
/// (docs/adr/0015-app-integration-and-catalog-traffic-privacy.md §1).
///
/// Without a URL for the build's region the catalog does not exist for the
/// app: no search, no scan, no card (CI builds rely on this). The app never
/// talks to another region's catalog.
class CatalogConfig {
  /// Creates a configuration; a null [baseUrl] disables the catalog.
  const CatalogConfig({this.baseUrl});

  /// A configuration without a catalog.
  const CatalogConfig.disabled() : baseUrl = null;

  /// Parses [spec] (`ru=url,eu=url`) and picks the URL of [region]; entries
  /// that are not `region=http(s)://host` are ignored.
  factory CatalogConfig.parse(String spec, {required String region}) {
    for (final entry in spec.split(',')) {
      final split = entry.indexOf('=');
      if (split < 0) {
        continue;
      }
      if (entry.substring(0, split).trim().toLowerCase() != region) {
        continue;
      }
      final url = Uri.tryParse(entry.substring(split + 1).trim());
      if (url != null && url.hasAuthority && _isWeb(url)) {
        return CatalogConfig(baseUrl: url);
      }
    }
    return const CatalogConfig.disabled();
  }

  /// Reads `PILLPAL_CATALOG_URLS` for [region] (`PILLPAL_REGION`). Release
  /// builds accept https only, like the API.
  factory CatalogConfig.fromEnvironment({
    required String region,
    bool allowInsecure = kDebugMode,
  }) {
    final config = CatalogConfig.parse(
      const String.fromEnvironment('PILLPAL_CATALOG_URLS'),
      region: region,
    );
    final url = config.baseUrl;
    if (url != null && url.scheme != 'https' && !allowInsecure) {
      throw StateError('The catalog URL must use https in release builds');
    }
    return config;
  }

  /// Server root of the catalog, or null when there is none.
  final Uri? baseUrl;

  /// Whether the build has a catalog; all catalog UI hangs on this.
  bool get enabled => baseUrl != null;

  /// The absolute URL of catalog [path] (which starts with `/`).
  Uri resolve(String path) {
    final base = baseUrl;
    if (base == null) {
      throw StateError('The catalog is not configured');
    }
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(path: '$basePath$path');
  }

  static bool _isWeb(Uri url) => url.scheme == 'https' || url.scheme == 'http';
}

/// Catalog timings and limits.
abstract final class CatalogPolicy {
  /// A cached product card older than this is fetched again when opened
  /// (ADR 0015 §2); there is no background refresh.
  static const Duration cardTtl = Duration(days: 30);

  /// The install id sent as `X-Catalog-Install` is replaced this often
  /// (ADR 0015 §3), besides at sign-out and account deletion.
  static const Duration installIdLifetime = Duration(days: 30);

  /// Consent text versions this app can record (`gtin_link_consent_version`).
  static const Set<int> knownConsentVersions = {1};

  /// Per-request timeout of catalog calls.
  static const Duration requestTimeout = Duration(seconds: 15);

  /// The catalog's `SearchRequest.q` bounds (characters).
  static const int searchMinLength = 2;

  /// Upper bound of `SearchRequest.q`.
  static const int searchMaxLength = 100;
}
