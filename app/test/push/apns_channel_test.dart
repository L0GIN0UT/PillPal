import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/push/apns_channel.dart';
import 'package:pillpal/src/push/push_provider_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const name = 'test/pillpal-push';
  late MethodChannel channel;
  late List<String> calls;
  late Object? registerAnswer;
  late Object? initialTapAnswer;

  setUp(() {
    channel = const MethodChannel(name);
    calls = [];
    registerAnswer = {'token': 'aabbcc', 'environment': 'sandbox'};
    initialTapAnswer = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'registerApns' => registerAnswer,
        'initialTap' => initialTapAnswer,
        _ => null,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> native(ApnsChannel apns, String method, Object? arguments) {
    return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      name,
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
  }

  test('is the apns provider; the system draws the alert', () async {
    final apns = ApnsChannel(channel);
    expect(apns.kind, PushProviderKind.apns);
    expect(apns.rendersLocally, isFalse);
    expect(await apns.isAvailable(), isTrue);
  });

  test('start returns the raw token with the environment of the build',
      () async {
    final apns = ApnsChannel(channel);
    expect(
      await apns.start(),
      const PushRegistration(token: 'aabbcc', apnsEnvironment: 'sandbox'),
    );
    expect(calls, ['registerApns']);
  });

  test('start has nothing without a token', () async {
    registerAnswer = {'token': ''};
    expect(await ApnsChannel(channel).start(), isNull);
    registerAnswer = null;
    expect(await ApnsChannel(channel).start(), isNull);
  });

  test('a token reported by the system is a refresh', () async {
    final apns = ApnsChannel(channel);
    final next = apns.refreshes.first;
    await native(
        apns, 'token', {'token': 'ddeeff', 'environment': 'production'});
    expect(
      await next,
      const PushRegistration(token: 'ddeeff', apnsEnvironment: 'production'),
    );
  });

  test('foreground pushes and taps keep string data only', () async {
    final apns = ApnsChannel(channel);
    final message = apns.messages.first;
    final tap = apns.taps.first;
    await native(apns, 'message', {'t': 'missed', 'extra': 1});
    await native(apns, 'tap', {'t': 'resolved', 3: 'x'});
    expect(await message, {'t': 'missed'});
    expect(await tap, {'t': 'resolved'});
  });

  test('the launching tap is read once from the native side', () async {
    initialTapAnswer = {'t': 'missed'};
    expect(await ApnsChannel(channel).initialTap(), {'t': 'missed'});
    initialTapAnswer = null;
    expect(await ApnsChannel(channel).initialTap(), isNull);
  });

  test('stop gives the registration back', () async {
    await ApnsChannel(channel).stop();
    expect(calls, ['unregisterApns']);
  });
}
