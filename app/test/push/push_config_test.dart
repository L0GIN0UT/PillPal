import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/push/push_config.dart';

PushConfig _config({
  String region = 'ru',
  String? apiKey = 'synthetic-api-key',
  String? appId = '1:000000000000:android:0000000000000000',
  String? senderId = '000000000000',
  String? projectId = 'synthetic-project',
  String? rustore = 'synthetic-rustore',
}) =>
    PushConfig.fromValues(
      region: region,
      fcmApiKey: apiKey,
      fcmAppId: appId,
      fcmSenderId: senderId,
      fcmProjectId: projectId,
      rustoreProjectId: rustore,
    );

void main() {
  test('a build without settings has no provider configured', () {
    final config = PushConfig.fromValues(region: 'ru');
    expect(config.fcmConfigured, isFalse);
    expect(config.rustoreConfigured, isFalse);
    expect(PushConfig.none.fcm, isNull);
  });

  test('empty defines, as the environment gives them, are not settings', () {
    final config = _config(
      apiKey: '',
      appId: '',
      senderId: '',
      projectId: '',
      rustore: '',
    );
    expect(config.fcmConfigured, isFalse);
    expect(config.rustoreConfigured, isFalse);
  });

  test('FCM needs all four values', () {
    expect(_config().fcmConfigured, isTrue);
    expect(_config(apiKey: null).fcmConfigured, isFalse);
    expect(_config(appId: '').fcmConfigured, isFalse);
    expect(_config(senderId: ' ').fcmConfigured, isFalse);
    expect(_config(projectId: null).fcmConfigured, isFalse);
  });

  test('FCM options carry the values', () {
    expect(
      _config().fcm,
      const FcmOptions(
        apiKey: 'synthetic-api-key',
        appId: '1:000000000000:android:0000000000000000',
        senderId: '000000000000',
        projectId: 'synthetic-project',
      ),
    );
  });

  test('a value with characters Gradle would not accept is not configured', () {
    expect(_config(apiKey: 'a"b').fcmConfigured, isFalse);
    expect(_config(projectId: 'a b').fcmConfigured, isFalse);
    expect(_config(rustore: "x'y").rustoreConfigured, isFalse);
  });

  test('RuStore is configured by its project id in the RU region only', () {
    expect(_config().rustoreProjectId, 'synthetic-rustore');
    expect(_config().rustoreConfigured, isTrue);
    expect(_config(region: 'eu').rustoreConfigured, isFalse);
    expect(_config(region: 'eu').fcmConfigured, isTrue);
  });
}
