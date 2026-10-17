import 'dart:async';

import 'package:flutter/services.dart';

import 'fcm_backend.dart';
import 'push_channel.dart';
import 'push_config.dart';
import 'push_provider_client.dart';

/// Whether Google Play services are on the device (native check, no
/// Firebase involved).
typedef GmsCheck = Future<bool> Function();

Future<bool> _nativeGmsAvailable() async {
  try {
    return await pushChannel.invokeMethod<bool>('gmsAvailable') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// FCM over `firebase_messaging` (ADR 0008 §1, §7).
///
/// Firebase is initialized from the build's `--dart-define`s, in [start]
/// (and in [stop], to take a token back): a build without them, a device
/// without Google services, or an account that never needed alerts leaves the
/// Firebase libraries idle. The Gradle side has no google-services plugin;
/// `build.gradle.kts` writes the same values as resources so the background
/// isolate of a data-only push can start the default app by itself.
class FcmClient implements PushProviderClient {
  /// Creates the client; [gmsAvailable] and [backend] are injected for tests.
  FcmClient({
    required FcmOptions? options,
    GmsCheck? gmsAvailable,
    FcmBackend backend = const FirebaseBackend(),
  })  : _options = options,
        _gmsAvailable = gmsAvailable ?? _nativeGmsAvailable,
        _backend = backend;

  final FcmOptions? _options;
  final GmsCheck _gmsAvailable;
  final FcmBackend _backend;
  bool _started = false;

  @override
  PushProviderKind get kind => PushProviderKind.fcm;

  @override
  bool get rendersLocally => true;

  @override
  Future<bool> isAvailable() async {
    return _options != null && await _gmsAvailable();
  }

  @override
  Future<PushRegistration?> start() async {
    final options = _options;
    if (options == null) {
      return null;
    }
    await _backend.initialize(options);
    if (!_started) {
      _backend.registerBackgroundHandler();
      await _backend.setAutoInit(enabled: true);
      _started = true;
    }
    final token = await _backend.getToken();
    return token == null ? null : PushRegistration(token: token);
  }

  @override
  Stream<PushRegistration> get refreshes {
    if (!_started) {
      return const Stream<PushRegistration>.empty();
    }
    return _backend.tokenRefreshes.map((token) => PushRegistration(token: token));
  }

  @override
  Stream<Map<String, String>> get messages {
    if (!_started) {
      return const Stream<Map<String, String>>.empty();
    }
    return _backend.messages;
  }

  /// Gives the token back. Firebase is initialized first if this process has
  /// not done it yet: after a cold start (or an erased account) the token of
  /// an earlier run still exists, and only an initialized app can delete it.
  @override
  Future<void> stop() async {
    final options = _options;
    if (options == null) {
      return;
    }
    await _backend.initialize(options);
    await _backend.deleteToken();
    await _backend.setAutoInit(enabled: false);
    _started = false;
  }
}
