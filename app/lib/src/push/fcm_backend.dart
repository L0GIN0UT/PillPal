import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'push_background_handler.dart';
import 'push_channel.dart';
import 'push_config.dart';

/// The Firebase calls [FcmClient] needs, apart from the library so that the
/// client's order of calls can be tested without a Firebase project.
abstract interface class FcmBackend {
  /// Makes sure the default Firebase app exists; idempotent.
  Future<void> initialize(FcmOptions options);

  /// Lets a data-only push reach `pushBackgroundHandler` while the app is in
  /// the background or terminated.
  void registerBackgroundHandler();

  /// Turns the automatic creation of a token on or off.
  Future<void> setAutoInit({required bool enabled});

  /// This installation's FCM registration token.
  Future<String?> getToken();

  /// Deletes the token: FCM stops delivering to it.
  Future<void> deleteToken();

  /// Tokens issued after the first one.
  Stream<String> get tokenRefreshes;

  /// Data of the pushes that arrive while the app runs.
  Stream<Map<String, String>> get messages;
}

/// [FcmBackend] over `firebase_core` and `firebase_messaging`.
class FirebaseBackend implements FcmBackend {
  /// Creates the backend; nothing is touched until a method is called.
  const FirebaseBackend();

  /// The native default app may exist already: Gradle writes the same
  /// settings as resources, and `FirebaseInitProvider` creates it at process
  /// start. Then Dart only picks it up.
  @override
  Future<void> initialize(FcmOptions options) async {
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
  void registerBackgroundHandler() {
    FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
  }

  @override
  Future<void> setAutoInit({required bool enabled}) =>
      FirebaseMessaging.instance.setAutoInitEnabled(enabled);

  @override
  Future<String?> getToken() => FirebaseMessaging.instance.getToken();

  @override
  Future<void> deleteToken() => FirebaseMessaging.instance.deleteToken();

  @override
  Stream<String> get tokenRefreshes =>
      FirebaseMessaging.instance.onTokenRefresh;

  @override
  Stream<Map<String, String>> get messages =>
      FirebaseMessaging.onMessage.map((message) => stringData(message.data));
}
