import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/push/fcm_client.dart';
import 'package:pillpal/src/push/push_config.dart';
import 'package:pillpal/src/push/push_provider_client.dart';

const FcmOptions _options = FcmOptions(
  apiKey: 'synthetic-key',
  appId: '1:123:android:abc',
  senderId: '123',
  projectId: 'synthetic-project',
);

void main() {
  test('is the fcm provider and draws notifications itself', () {
    final client = FcmClient(options: _options, gmsAvailable: () async => true);
    expect(client.kind, PushProviderKind.fcm);
    expect(client.rendersLocally, isTrue);
  });

  test('is available with settings and Google services', () async {
    final client = FcmClient(options: _options, gmsAvailable: () async => true);
    expect(await client.isAvailable(), isTrue);
  });

  test('is not available without Google services', () async {
    final client =
        FcmClient(options: _options, gmsAvailable: () async => false);
    expect(await client.isAvailable(), isFalse);
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
    );
    expect(await client.isAvailable(), isFalse);
    expect(asked, isFalse);
    expect(await client.start(), isNull);
  });

  test('before start it has no streams to listen to', () async {
    final client = FcmClient(options: _options, gmsAvailable: () async => true);
    expect(await client.refreshes.isEmpty, isTrue);
    expect(await client.messages.isEmpty, isTrue);
  });
}
