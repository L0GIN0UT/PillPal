import 'package:flutter/foundation.dart';

/// The identifiers of the Firebase project of this build (a registered
/// Android app). They are not secrets (`firebase.google.com/docs/flutter/setup`
/// puts them in the app), but they come from the build, never from the
/// repository: no `google-services.json` exists (ADR 0008 §7).
@immutable
class FcmOptions {
  /// Creates options from the four values Firebase requires.
  const FcmOptions({
    required this.apiKey,
    required this.appId,
    required this.senderId,
    required this.projectId,
  });

  /// `PILLPAL_FCM_API_KEY`.
  final String apiKey;

  /// `PILLPAL_FCM_APP_ID`, the Android app id (`1:...:android:...`).
  final String appId;

  /// `PILLPAL_FCM_SENDER_ID`, the messaging sender id.
  final String senderId;

  /// `PILLPAL_FCM_PROJECT_ID`.
  final String projectId;

  @override
  bool operator ==(Object other) =>
      other is FcmOptions &&
      other.apiKey == apiKey &&
      other.appId == appId &&
      other.senderId == senderId &&
      other.projectId == projectId;

  @override
  int get hashCode => Object.hash(apiKey, appId, senderId, projectId);
}

/// Characters of a Firebase or RuStore identifier. `build.gradle.kts` applies
/// the same check before it writes the values into resources and the
/// manifest, so Dart and Gradle agree on what counts as configured.
final RegExp _identifierPattern = RegExp(r'^[A-Za-z0-9_:.\-]+$');

String? _identifier(String? value) {
  final trimmed = value?.trim();
  return trimmed != null && _identifierPattern.hasMatch(trimmed)
      ? trimmed
      : null;
}

/// Which push providers this build has settings for (all optional: without
/// them the push clients stay off and the app builds and runs as before).
///
/// The settings are `--dart-define`s, filled in `app-release.yml` from
/// repository variables; Gradle reads the same defines for the native side.
@immutable
class PushConfig {
  /// Creates a configuration.
  const PushConfig({this.fcm, this.rustoreProjectId});

  /// A build without push settings.
  static const PushConfig none = PushConfig();

  /// Builds the configuration from the raw define values. FCM needs all four
  /// values; a partial set counts as not configured. RuStore Push exists in
  /// the RU region only (the server refuses its tokens elsewhere, ADR 0008
  /// §5), so [region] other than `ru` turns it off.
  factory PushConfig.fromValues({
    required String region,
    String? fcmApiKey,
    String? fcmAppId,
    String? fcmSenderId,
    String? fcmProjectId,
    String? rustoreProjectId,
  }) {
    final apiKey = _identifier(fcmApiKey);
    final appId = _identifier(fcmAppId);
    final senderId = _identifier(fcmSenderId);
    final projectId = _identifier(fcmProjectId);
    final configured = apiKey != null &&
        appId != null &&
        senderId != null &&
        projectId != null;
    return PushConfig(
      fcm: configured
          ? FcmOptions(
              apiKey: apiKey,
              appId: appId,
              senderId: senderId,
              projectId: projectId,
            )
          : null,
      rustoreProjectId: region == 'ru' ? _identifier(rustoreProjectId) : null,
    );
  }

  /// Reads the `PILLPAL_FCM_*` and `PILLPAL_RUSTORE_PROJECT_ID` defines.
  factory PushConfig.fromEnvironment({required String region}) {
    return PushConfig.fromValues(
      region: region,
      fcmApiKey: const String.fromEnvironment('PILLPAL_FCM_API_KEY'),
      fcmAppId: const String.fromEnvironment('PILLPAL_FCM_APP_ID'),
      fcmSenderId: const String.fromEnvironment('PILLPAL_FCM_SENDER_ID'),
      fcmProjectId: const String.fromEnvironment('PILLPAL_FCM_PROJECT_ID'),
      rustoreProjectId: const String.fromEnvironment(
        'PILLPAL_RUSTORE_PROJECT_ID',
      ),
    );
  }

  /// Firebase options, or null: FCM is not configured.
  final FcmOptions? fcm;

  /// RuStore project id, or null: RuStore Push is not configured.
  final String? rustoreProjectId;

  /// Whether FCM may be used.
  bool get fcmConfigured => fcm != null;

  /// Whether RuStore Push may be used.
  bool get rustoreConfigured => rustoreProjectId != null;
}
