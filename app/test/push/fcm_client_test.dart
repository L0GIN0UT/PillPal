import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/push/fcm_backend.dart';
import 'package:pillpal/src/push/fcm_client.dart';
import 'package:pillpal/src/push/push_config.dart';
import 'package:pillpal/src/push/push_provider_client.dart';

const FcmOptions _options = FcmOptions(
  apiKey: 'synthetic-key',
  appId: '1:123:android:abc',
  senderId: '123',
  projectId: 'synthetic-project',
);

class _FakeBackend implements FcmBackend {
  final List<String> calls = [];
  String? token = 'synthetic-fcm-token';
  Object? deleteError;

  @override
  Future<void> initialize(FcmOptions options) async => calls.add('initialize');

  @override
  void registerBackgroundHandler() => calls.add('backgroundHandler');

  @override
  Future<void> setAutoInit({required bool enabled}) async =>
      calls.add('autoInit:$enabled');

  @override
  Future<String?> getToken() async {
    calls.add('getToken');
    return token;
  }

  @override
  Future<void> deleteToken() async {
    calls.add('deleteToken');
    final error = deleteError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Stream<String> get tokenRefreshes => const Stream<String>.empty();

  @override
  Stream<Map<String, String>> get messages =>
      const Stream<Map<String, String>>.empty();
}

void main() {
  late _FakeBackend backend;

  FcmClient build({FcmOptions? options = _options, bool gms = true}) =>
      FcmClient(
        options: options,
        gmsAvailable: () async => gms,
        backend: backend,
      );

  setUp(() => backend = _FakeBackend());

  test('is the fcm provider and draws notifications itself', () {
    final client = build();
    expect(client.kind, PushProviderKind.fcm);
    expect(client.rendersLocally, isTrue);
  });

  test('is available with settings and Google services', () async {
    expect(await build().isAvailable(), isTrue);
  });

  test('is not available without Google services', () async {
    expect(await build(gms: false).isAvailable(), isFalse);
  });

  test('is not available without settings, and never asks the platform',
      () async {
    var asked = false;
    final client = FcmClient(
      options: null,
      gmsAvailable: () async {
        asked = true;
        return true;
      },
      backend: backend,
    );
    expect(await client.isAvailable(), isFalse);
    expect(asked, isFalse);
    expect(await client.start(), isNull);
    await client.stop();
    expect(backend.calls, isEmpty);
  });

  test('start initializes Firebase, enables the token and returns it',
      () async {
    final registration = await build().start();
    expect(registration, const PushRegistration(token: 'synthetic-fcm-token'));
    expect(backend.calls, [
      'initialize',
      'backgroundHandler',
      'autoInit:true',
      'getToken',
    ]);
  });

  test('a second start only asks for the token again', () async {
    final client = build();
    await client.start();
    backend.calls.clear();
    await client.start();
    expect(backend.calls, ['initialize', 'getToken']);
  });

  test('stop on a cold start still initializes Firebase and deletes the token',
      () async {
    // A new client: this process never started FCM, the token is from an
    // earlier run.
    await build().stop();
    expect(backend.calls, ['initialize', 'deleteToken', 'autoInit:false']);
  });

  test('a token that cannot be deleted is an error for the caller', () async {
    backend.deleteError = StateError('offline');
    await expectLater(build().stop(), throwsStateError);
    expect(backend.calls, isNot(contains('autoInit:false')));
  });

  test('before start it has no streams to listen to', () async {
    final client = build();
    expect(await client.refreshes.isEmpty, isTrue);
    expect(await client.messages.isEmpty, isTrue);
  });
}
