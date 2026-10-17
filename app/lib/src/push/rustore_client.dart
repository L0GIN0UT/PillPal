import 'dart:async';

import 'package:flutter_rustore_push/flutter_rustore_push.dart';
import 'package:flutter_rustore_push/pigeons/rustore_push.dart' as rustore;

import 'push_channel.dart';
import 'push_provider_client.dart';

/// RuStore Push over `flutter_rustore_push` (ADR 0008 §1). Android devices
/// without Google services in the RU region; the project id reaches the
/// native SDK through the `rustoreProjectId` manifest placeholder, and
/// without it the plugin is not initialized at all (so this client is not
/// even built then, see `PushConfig.rustoreConfigured`).
class RuStoreClient implements PushProviderClient {
  /// Creates the client for a configured RuStore project.
  RuStoreClient({required String? projectId}) : _projectId = projectId;

  final String? _projectId;
  final StreamController<PushRegistration> _refreshes =
      StreamController<PushRegistration>.broadcast();
  final StreamController<Map<String, String>> _messages =
      StreamController<Map<String, String>>.broadcast();
  bool _attached = false;

  @override
  PushProviderKind get kind => PushProviderKind.rustore;

  @override
  bool get rendersLocally => true;

  @override
  Future<bool> isAvailable() async {
    if (_projectId == null) {
      return false;
    }
    try {
      return await RustorePushClient.available();
    } on Object {
      // The RuStore app is not installed or cannot deliver.
      return false;
    }
  }

  @override
  Future<PushRegistration?> start() async {
    if (_projectId == null) {
      return null;
    }
    await _attachCallbacks();
    final token = await RustorePushClient.getToken();
    return token.isEmpty ? null : PushRegistration(token: token);
  }

  Future<void> _attachCallbacks() async {
    if (_attached) {
      return;
    }
    _attached = true;
    await RustorePushClient.attachCallbacks(
      onNewToken: (Object? token) {
        if (token is String && token.isNotEmpty) {
          _refreshes.add(PushRegistration(token: token));
        }
      },
      onMessageReceived: (Object? message) {
        if (message is rustore.Message) {
          _messages.add(stringData(message.data));
        }
      },
    );
  }

  @override
  Stream<PushRegistration> get refreshes => _refreshes.stream;

  @override
  Stream<Map<String, String>> get messages => _messages.stream;

  @override
  Future<void> stop() async {
    if (_projectId == null) {
      return;
    }
    await RustorePushClient.deleteToken();
  }
}
