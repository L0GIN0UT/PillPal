import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';

import 'push_background_handler.dart';
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
/// only: a build without them, a device without Google services, or an
/// account that needs no alerts never touches Firebase. The Gradle side
/// has no google-services plugin; `build.gradle.kts` writes the same values
/// as resources so the background isolate of a data-only push can start
/// the default app by itself.
class FcmClient implements PushProviderClient {
  /// Creates the client; [gmsAvailable] is injected for tests.
  FcmClient({required FcmOptions? options, GmsCheck? gmsAvailable})
      : _options = options,
        _gmsAvailable = gmsAvailable ?? _nativeGmsAvailable;

  final FcmOptions? _options;
  final GmsCheck _gmsAvailable;
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
    await _initializeFirebase(options);
    final messaging = FirebaseMessaging.instance;
    if (!_started) {
      FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
      await messaging.setAutoInitEnabled(true);
      _started = true;
    }
    final token = await messaging.getToken();
    return token == null ? null : PushRegistration(token: token);
  }

  /// The native default app may exist already: Gradle writes the same
  /// settings as resources, and `FirebaseInitProvider` creates it at process
  /// start. Then Dart only picks it up.
  Future<void> _initializeFirebase(FcmOptions options) async {
    if (Firebase.apps.isNotEmpty) {
      return;
    }
    try {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: options.apiKey,
          appId: options.appId,
          messagingSenderId: options.senderId,
          projectId: options.projectId,
        ),
      );
    } on FirebaseException catch (error) {
      if (error.code != 'duplicate-app') {
        rethrow;
      }
    }
  }

  @override
  Stream<PushRegistration> get refreshes {
    if (!_started) {
      return const Stream<PushRegistration>.empty();
    }
    return FirebaseMessaging.instance.onTokenRefresh
        .map((token) => PushRegistration(token: token));
  }

  @override
  Stream<Map<String, String>> get messages {
    if (!_started) {
      return const Stream<Map<String, String>>.empty();
    }
    return FirebaseMessaging.onMessage
        .map((message) => stringData(message.data));
  }

  @override
  Future<void> stop() async {
    if (!_started && Firebase.apps.isEmpty) {
      return;
    }
    final messaging = FirebaseMessaging.instance;
    await messaging.deleteToken();
    await messaging.setAutoInitEnabled(false);
    _started = false;
  }
}
