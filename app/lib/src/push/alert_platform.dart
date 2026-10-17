import 'dart:async';

import 'package:flutter/services.dart';

/// The native `pillpal/alerts` channel of the `pillpal_alerts` plugin
/// (Android). It posts the alert notifications itself because only native
/// code can attach the redacted public version a secure lock screen shows,
/// and because a local plugin is registered in the background engine of a
/// data-only push as well, where `MainActivity` does not exist.
class AlertPlatform {
  /// Creates the platform over [channel] (injected for tests).
  AlertPlatform([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel('pillpal/alerts') {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  final MethodChannel _channel;
  final StreamController<String> _taps = StreamController<String>.broadcast();

  /// Payloads of the alerts the user tapped while the app was running.
  Stream<String> get taps => _taps.stream;

  Future<Object?> _onNativeCall(MethodCall call) async {
    final arguments = call.arguments;
    if (call.method == 'tap' && arguments is String) {
      _taps.add(arguments);
    }
    return null;
  }

  /// Creates the notification channel (idempotent: an existing channel keeps
  /// the user's settings).
  Future<void> prepare({
    required String channelId,
    required String name,
    required String description,
  }) {
    return _channel.invokeMethod<void>('prepare', {
      'channelId': channelId,
      'name': name,
      'description': description,
    });
  }

  /// Posts or replaces a notification.
  Future<void> show(Map<String, Object?> arguments) {
    return _channel.invokeMethod<void>('show', arguments);
  }

  /// Whether a notification with [id] is in the tray; false when the platform
  /// cannot tell.
  Future<bool> isShown(int id) async {
    try {
      return await _channel.invokeMethod<bool>('isShown', {'id': id}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// The payload of the alert that launched the app, once.
  Future<String?> launchPayload() async {
    try {
      return await _channel.invokeMethod<String>('launchPayload');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
