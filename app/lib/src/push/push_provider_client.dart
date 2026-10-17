import 'package:flutter/foundation.dart';

/// The push providers a device can register with (`push_tokens.provider`).
enum PushProviderKind {
  /// Firebase Cloud Messaging: Android with Google Play services.
  fcm('fcm'),

  /// Apple Push Notification service: iOS.
  apns('apns'),

  /// RuStore Push: Android without Google Play services (RU region).
  rustore('rustore');

  const PushProviderKind(this.wire);

  /// The value of `provider` in the API.
  final String wire;

  /// The provider named [wire], or null.
  static PushProviderKind? fromWire(String? wire) {
    for (final kind in values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    return null;
  }
}

/// What a provider hands out for this installation: the token the backend
/// sends to, and for APNs the environment of the build (`sandbox` or
/// `production`; a token of the wrong one is refused by Apple).
@immutable
class PushRegistration {
  /// Creates a registration.
  const PushRegistration({required this.token, this.apnsEnvironment});

  /// The opaque provider token (never logged).
  final String token;

  /// `sandbox` or `production`, APNs only.
  final String? apnsEnvironment;

  @override
  bool operator ==(Object other) =>
      other is PushRegistration &&
      other.token == token &&
      other.apnsEnvironment == apnsEnvironment;

  @override
  int get hashCode => Object.hash(token, apnsEnvironment);
}

/// One push provider as the app uses it. A client does nothing until
/// [start] is called: the app initializes Firebase or RuStore only while
/// relative alerts are needed (ADR 0008 §1).
abstract interface class PushProviderClient {
  /// The provider this client talks to.
  PushProviderKind get kind;

  /// Whether this device can use the provider: the build has its settings,
  /// the platform services exist. Does not start anything.
  Future<bool> isAvailable();

  /// Starts the provider (idempotent) and returns this installation's
  /// registration; null when the provider has none to give.
  Future<PushRegistration?> start();

  /// A new registration after [start] (the provider rotated the token).
  Stream<PushRegistration> get refreshes;

  /// Data of the pushes that arrive while the app runs.
  Stream<Map<String, String>> get messages;

  /// Whether the app draws the notification itself from [messages] (data-only
  /// pushes of FCM and RuStore). APNs alerts are drawn by the system.
  bool get rendersLocally;

  /// Gives the token back: the provider stops delivering to this
  /// installation. Idempotent.
  Future<void> stop();
}

/// Picks the provider of this device (ADR 0008 §1): iOS uses APNs; Android
/// uses FCM when the device has Google Play services and the build has
/// Firebase settings, else RuStore Push when the build has a RuStore project
/// and the RuStore app can deliver; otherwise none.
class PushProviderSelector {
  /// Creates a selector; a client that does not exist on a platform is null.
  const PushProviderSelector({
    required this.platform,
    this.fcm,
    this.apns,
    this.rustore,
  });

  /// The platform the app runs on.
  final TargetPlatform platform;

  /// The FCM client.
  final PushProviderClient? fcm;

  /// The APNs client.
  final PushProviderClient? apns;

  /// The RuStore client.
  final PushProviderClient? rustore;

  /// The client to register with, or null when the device has no provider.
  Future<PushProviderClient?> select() async {
    final candidates = switch (platform) {
      TargetPlatform.iOS => [apns],
      TargetPlatform.android => [fcm, rustore],
      _ => <PushProviderClient?>[],
    };
    for (final candidate in candidates) {
      if (candidate != null && await _usable(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  /// Every client this platform has, usable or not: sign-out stops them all.
  Iterable<PushProviderClient> get clients =>
      [fcm, apns, rustore].whereType<PushProviderClient>();

  /// The client of [kind], whether or not it is usable now.
  PushProviderClient? clientOf(PushProviderKind kind) => switch (kind) {
        PushProviderKind.fcm => fcm,
        PushProviderKind.apns => apns,
        PushProviderKind.rustore => rustore,
      };

  /// A check that throws counts as "not usable": the next provider is tried.
  Future<bool> _usable(PushProviderClient client) async {
    try {
      return await client.isAvailable();
    } on Object {
      return false;
    }
  }
}
