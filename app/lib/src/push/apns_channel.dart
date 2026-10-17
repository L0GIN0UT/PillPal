import 'dart:async';

import 'package:flutter/services.dart';

import 'push_channel.dart';
import 'push_provider_client.dart';

/// APNs through the native `pillpal/push` channel (ADR 0008 §1: the raw
/// device token, no Firebase on iOS). `AppDelegate.swift` asks the system
/// to register for remote notifications, reports the token, and hands
/// over taps and foreground pushes.
class ApnsChannel implements PushProviderClient {
  /// Creates the client over [channel] (injected for tests).
  ApnsChannel([MethodChannel? channel]) : _channel = channel ?? pushChannel {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  final MethodChannel _channel;
  final StreamController<PushRegistration> _refreshes =
      StreamController<PushRegistration>.broadcast();
  final StreamController<Map<String, String>> _messages =
      StreamController<Map<String, String>>.broadcast();
  final StreamController<Map<String, String>> _taps =
      StreamController<Map<String, String>>.broadcast();

  @override
  PushProviderKind get kind => PushProviderKind.apns;

  /// The system draws the alert from the APNs payload (loc-key).
  @override
  bool get rendersLocally => false;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<PushRegistration?> start() async {
    final result = await _channel.invokeMapMethod<String, String>(
      'registerApns',
    );
    return _registration(result);
  }

  PushRegistration? _registration(Map<Object?, Object?>? raw) {
    final token = raw?['token'];
    if (token is! String || token.isEmpty) {
      return null;
    }
    final environment = raw?['environment'];
    return PushRegistration(
      token: token,
      apnsEnvironment: environment is String ? environment : null,
    );
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    final arguments = call.arguments;
    final map = arguments is Map<Object?, Object?> ? arguments : null;
    switch (call.method) {
      case 'token':
        final registration = _registration(map);
        if (registration != null) {
          _refreshes.add(registration);
        }
      case 'message':
        _messages.add(stringData(map));
      case 'tap':
        _taps.add(stringData(map));
    }
    return null;
  }

  /// The data of the push the user tapped to launch the app, once.
  Future<Map<String, String>?> initialTap() async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>('initialTap');
    return raw == null ? null : stringData(raw);
  }

  /// Taps on alerts while the app runs or sits in the background.
  Stream<Map<String, String>> get taps => _taps.stream;

  @override
  Stream<PushRegistration> get refreshes => _refreshes.stream;

  @override
  Stream<Map<String, String>> get messages => _messages.stream;

  @override
  Future<void> stop() async {
    await _channel.invokeMethod<void>('unregisterApns');
  }
}
