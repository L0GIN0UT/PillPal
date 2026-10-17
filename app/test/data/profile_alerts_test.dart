import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/repositories/local_writer.dart';

import 'test_env.dart';

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  Future<String> managed() =>
      env.profiles.create(displayName: 'Ward', timezone: 'Europe/Samara');

  test('update stores the alert settings and queues them for push', () async {
    final id = await managed();
    await env.profiles.update(
      id,
      missedAlertMinutes: 90,
      missedAlertsEnabled: false,
    );

    final row = (await env.profiles.find(id))!;
    expect(row.missedAlertMinutes, 90);
    expect(row.missedAlertsEnabled, isFalse);
    final last = (await env.outbox()).last;
    final payload = jsonDecode(last.payload!) as Map<String, Object?>;
    expect(payload['missed_alert_minutes'], 90);
    expect(payload['missed_alerts_enabled'], false);
  });

  test('a plain rename keeps the alert settings', () async {
    final id = await managed();
    await env.profiles.update(id, missedAlertMinutes: 45);
    await env.profiles.update(id, displayName: 'Ward B');

    final row = (await env.profiles.find(id))!;
    expect(row.displayName, 'Ward B');
    expect(row.missedAlertMinutes, 45);
  });

  test('alert minutes outside 5..720 are refused', () async {
    final id = await managed();
    for (final minutes in [4, 721, 0, -1]) {
      await expectLater(
        env.profiles.update(id, missedAlertMinutes: minutes),
        throwsA(
          isA<DataException>()
              .having((e) => e.field, 'field', 'missed_alert_minutes'),
        ),
        reason: '$minutes',
      );
    }
    await env.profiles.update(id, missedAlertMinutes: 5);
    await env.profiles.update(id, missedAlertMinutes: 720);
  });
}
