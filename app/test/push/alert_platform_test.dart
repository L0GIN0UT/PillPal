import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/push/alert_notification_sink.dart';
import 'package:pillpal/src/push/alert_platform.dart';
import 'package:pillpal/src/push/relatives_alert_notifier.dart';
import 'package:pillpal/src/reminders/reminder_content.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const name = 'test/pillpal-alerts';
  late MethodChannel channel;
  late List<MethodCall> calls;
  late Object? shownAnswer;
  late Object? launchAnswer;

  setUp(() {
    channel = const MethodChannel(name);
    calls = [];
    shownAnswer = true;
    launchAnswer = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'isShown' => shownAnswer,
        'launchPayload' => launchAnswer,
        _ => null,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> native(String method, Object? arguments) {
    return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      name,
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
  }

  group('the sink', () {
    test('sends the redacted public version along with the text', () async {
      final strings = reminderStrings(const Locale('en'));
      final sink = PlatformAlertNotificationSink(
        strings,
        AlertPlatform(channel),
      );
      await sink.show(
        const AlertNotification(
          id: 0x40000001,
          title: 'Title',
          body: 'Body',
          payload: '{"v":1}',
          publicTitle: 'Public title',
          publicBody: 'Public body',
          quiet: true,
        ),
      );
      final call = calls.single;
      expect(call.method, 'show');
      final arguments = call.arguments as Map<Object?, Object?>;
      expect(arguments['id'], 0x40000001);
      expect(arguments['title'], 'Title');
      expect(arguments['body'], 'Body');
      expect(arguments['publicTitle'], 'Public title');
      expect(arguments['publicBody'], 'Public body');
      expect(arguments['payload'], '{"v":1}');
      expect(arguments['quiet'], isTrue);
      expect(arguments['channelId'], relativesAlertsChannelId);
      expect(relativesAlertsChannelId, 'relatives_alerts_v1');
    });

    test('prepare creates the channel with localized names', () async {
      final strings = reminderStrings(const Locale('en'));
      await PlatformAlertNotificationSink(strings, AlertPlatform(channel))
          .prepare();
      final arguments = calls.single.arguments as Map<Object?, Object?>;
      expect(calls.single.method, 'prepare');
      expect(arguments['channelId'], relativesAlertsChannelId);
      expect(arguments['name'], strings.relativesAlertChannelName);
      expect(
          arguments['description'], strings.relativesAlertChannelDescription);
    });

    test('isShown asks the system about the id', () async {
      final strings = reminderStrings(const Locale('en'));
      final sink = PlatformAlertNotificationSink(
        strings,
        AlertPlatform(channel),
      );
      expect(await sink.isShown(7), isTrue);
      expect((calls.single.arguments as Map<Object?, Object?>)['id'], 7);
      shownAnswer = null;
      expect(await sink.isShown(7), isFalse);
    });

    test('an unavailable platform means "not shown", not an error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final strings = reminderStrings(const Locale('en'));
      final sink = PlatformAlertNotificationSink(
        strings,
        AlertPlatform(channel),
      );
      expect(await sink.isShown(7), isFalse);
    });
  });

  group('taps', () {
    test('a tap while the app runs arrives as the payload', () async {
      final platform = AlertPlatform(channel);
      final tap = platform.taps.first;
      await native('tap', '{"v":1}');
      expect(await tap, '{"v":1}');
    });

    test('anything that is not a string is dropped', () async {
      final platform = AlertPlatform(channel);
      final taps = <String>[];
      platform.taps.listen(taps.add);
      await native('tap', 5);
      await native('tap', null);
      await Future<void>.delayed(Duration.zero);
      expect(taps, isEmpty);
    });

    test('the launching tap is read from the native side', () async {
      launchAnswer = '{"v":1}';
      expect(await AlertPlatform(channel).launchPayload(), '{"v":1}');
      launchAnswer = null;
      expect(await AlertPlatform(channel).launchPayload(), isNull);
    });
  });
}
