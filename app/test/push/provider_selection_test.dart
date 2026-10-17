import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/push/push_provider_client.dart';

import 'fake_push.dart';

PushProviderSelector _selector(
  TargetPlatform platform, {
  FakePushClient? fcm,
  FakePushClient? apns,
  FakePushClient? rustore,
}) =>
    PushProviderSelector(
      platform: platform,
      fcm: fcm,
      apns: apns,
      rustore: rustore,
    );

void main() {
  FakePushClient fcm({bool available = true}) =>
      FakePushClient(PushProviderKind.fcm, available: available);
  FakePushClient rustore({bool available = true}) =>
      FakePushClient(PushProviderKind.rustore, available: available);
  FakePushClient apns() => FakePushClient(PushProviderKind.apns);

  test('iOS uses APNs, whatever else exists', () async {
    final selector = _selector(
      TargetPlatform.iOS,
      fcm: fcm(),
      apns: apns(),
      rustore: rustore(),
    );
    expect((await selector.select())?.kind, PushProviderKind.apns);
  });

  test('Android with Google services and FCM settings uses FCM', () async {
    final selector = _selector(
      TargetPlatform.android,
      fcm: fcm(),
      rustore: rustore(),
    );
    expect((await selector.select())?.kind, PushProviderKind.fcm);
  });

  test('Android falls back to RuStore when FCM cannot be used', () async {
    final selector = _selector(
      TargetPlatform.android,
      fcm: fcm(available: false),
      rustore: rustore(),
    );
    expect((await selector.select())?.kind, PushProviderKind.rustore);
  });

  test('Android with neither provider has none', () async {
    final selector = _selector(
      TargetPlatform.android,
      fcm: fcm(available: false),
      rustore: rustore(available: false),
    );
    expect(await selector.select(), isNull);
  });

  test('a provider whose check fails counts as unavailable', () async {
    final broken = fcm()..availabilityError = StateError('no platform');
    final selector = _selector(
      TargetPlatform.android,
      fcm: broken,
      rustore: rustore(),
    );
    expect((await selector.select())?.kind, PushProviderKind.rustore);
  });

  test('a provider the build does not have is skipped', () async {
    expect(
      (await _selector(TargetPlatform.android, rustore: rustore()).select())
          ?.kind,
      PushProviderKind.rustore,
    );
    expect(await _selector(TargetPlatform.android).select(), isNull);
  });

  test('other platforms have no provider', () async {
    final selector = _selector(
      TargetPlatform.linux,
      fcm: fcm(),
      apns: apns(),
      rustore: rustore(),
    );
    expect(await selector.select(), isNull);
  });

  test('the client of a kind is found even when it is not usable', () {
    final client = fcm(available: false);
    final selector = _selector(TargetPlatform.android, fcm: client);
    expect(selector.clientOf(PushProviderKind.fcm), same(client));
    expect(selector.clientOf(PushProviderKind.apns), isNull);
  });

  test('provider names match the API', () {
    expect(PushProviderKind.fromWire('rustore'), PushProviderKind.rustore);
    expect(PushProviderKind.fromWire('gcm'), isNull);
    expect(PushProviderKind.apns.wire, 'apns');
  });
}
