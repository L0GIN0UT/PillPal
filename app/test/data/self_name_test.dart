import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/local_writer.dart';
import 'package:pillpal/src/data/repositories/validation.dart';

import 'test_env.dart';

// A person's own name (the `self` profile) follows `PersonName` on rename,
// like the server's sync push: 2..20 code points, trimmed, no control
// characters. Managed profiles keep `DisplayName` (1..100).

const _selfId = '0b9a3c5e-1d2f-4a6b-8c7d-9e0f1a2b3c4d';

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  Future<void> seedSelf(String name) {
    return env.db.into(env.db.profiles).insert(
          ProfileRow(
            id: _selfId,
            kind: 'self',
            displayName: name,
            timezone: 'Europe/Samara',
            clientUpdatedAt: env.clock.now.microsecondsSinceEpoch,
            updatedByDevice: 'server-device',
            missedAlertMinutes: 30,
            missedAlertsEnabled: true,
          ),
        );
  }

  group('isPersonName', () {
    for (final name in ['Аня', '  Ivan  ', 'Jo', 'x' * 20, '👵🏻 Бабушка']) {
      test('accepts ${jsonEncode(name)}', () {
        expect(isPersonName(name), isTrue);
      });
    }
    for (final name in ['', '   ', 'A', ' A ', 'x' * 21, 'Iv\tan', 'Iv\nan']) {
      test('refuses ${jsonEncode(name)}', () {
        expect(isPersonName(name), isFalse);
      });
    }

    test('counts code points like the server', () {
      // Two emoji are four UTF-16 units but two code points.
      expect(isPersonName('😀😀'), isTrue);
      expect(isPersonName('😀' * 21), isFalse);
    });
  });

  test('renaming yourself stores the trimmed name and queues it', () async {
    await seedSelf('Test User');
    await env.profiles.update(_selfId, displayName: '  Мария  ');

    expect((await env.profiles.find(_selfId))!.displayName, 'Мария');
    final payload = jsonDecode((await env.outbox()).single.payload!)
        as Map<String, Object?>;
    expect(payload['display_name'], 'Мария');
    expect(payload['kind'], 'self');
  });

  for (final name in ['A', 'x' * 21, 'Grandmother Alexandra Long']) {
    test('renaming yourself to ${jsonEncode(name)} is refused', () async {
      await seedSelf('Test User');
      await expectLater(
        env.profiles.update(_selfId, displayName: name),
        throwsA(
          isA<DataException>()
              .having((e) => e.code, 'code', DataException.validationError),
        ),
      );
      expect((await env.profiles.find(_selfId))!.displayName, 'Test User');
      expect(await env.outbox(), isEmpty);
    });
  }

  test('an unchanged older name passes other edits', () async {
    await seedSelf('M');
    await env.profiles.update(
      _selfId,
      displayName: 'M',
      timezone: 'Asia/Omsk',
    );

    final row = await env.profiles.find(_selfId);
    expect(row!.displayName, 'M');
    expect(row.timezone, 'Asia/Omsk');
  });

  test('a managed profile keeps the wide rule', () async {
    final id = await env.profiles.create(
      displayName: 'Kid',
      timezone: 'Europe/Samara',
    );
    await env.profiles.update(id, displayName: 'K');

    expect((await env.profiles.find(id))!.displayName, 'K');
  });
}
