import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/local_writer.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';

import 'test_env.dart';

Matcher _invalid(String field) => throwsA(
      isA<DataException>()
          .having((e) => e.code, 'code', DataException.validationError)
          .having((e) => e.field, 'field', field),
    );

void main() {
  late TestEnv env;
  late String profile;

  setUp(() async {
    env = TestEnv();
    profile = await env.profiles.create(displayName: 'P', timezone: 'UTC');
  });
  tearDown(() => env.dispose());

  Future<String> med(MedicationDraft draft) =>
      env.medications.create(profileId: profile, draft: draft);

  group('profiles', () {
    test('display_name is trimmed, 1..100 code points', () async {
      final id = await env.profiles.create(
        displayName: '  ${'😀' * 100}  ',
        timezone: 'Europe/Samara',
      );
      expect((await env.profiles.find(id))!.displayName, '😀' * 100);
      await expectLater(
        env.profiles.create(displayName: 'x' * 101, timezone: 'UTC'),
        _invalid('display_name'),
      );
      await expectLater(
        env.profiles.create(displayName: '   ', timezone: 'UTC'),
        _invalid('display_name'),
      );
      await expectLater(
        env.profiles.create(displayName: 'a\u0007b', timezone: 'UTC'),
        _invalid('display_name'),
      );
    });

    test('timezone must be a known IANA zone', () async {
      await expectLater(
        env.profiles.create(displayName: 'P', timezone: 'Mars/Olympus'),
        _invalid('timezone'),
      );
      await expectLater(
        env.profiles.update(profile, timezone: ''),
        _invalid('timezone'),
      );
    });
  });

  group('medications', () {
    test('name is trimmed, 1..200', () async {
      final id = await med(MedicationDraft(name: ' ${'n' * 200} '));
      expect((await env.medications.find(id))!.name, 'n' * 200);
      await expectLater(med(MedicationDraft(name: 'n' * 201)), _invalid('name'));
      await expectLater(med(const MedicationDraft(name: '')), _invalid('name'));
    });

    test('optional texts: empty becomes null, limits apply', () async {
      final id = await med(
        MedicationDraft(
          name: 'M',
          form: '  ',
          strengthText: 's' * 100,
          notes: 'n' * 2000,
          stockUnit: 'u' * 32,
        ),
      );
      final row = (await env.medications.find(id))!;
      expect(row.form, isNull);
      expect(row.notes, hasLength(2000));
      await expectLater(
        med(MedicationDraft(name: 'M', strengthText: 's' * 101)),
        _invalid('strength_text'),
      );
      await expectLater(
        med(MedicationDraft(name: 'M', notes: 'n' * 2001)),
        _invalid('notes'),
      );
      await expectLater(
        med(MedicationDraft(name: 'M', stockUnit: 'u' * 33)),
        _invalid('stock_unit'),
      );
    });

    test('fixed_tz is required iff tz_mode is fixed', () async {
      await med(const MedicationDraft(
        name: 'M',
        tzMode: 'fixed',
        fixedTz: 'America/New_York',
      ));
      await expectLater(
        med(const MedicationDraft(name: 'M', tzMode: 'fixed')),
        _invalid('fixed_tz'),
      );
      await expectLater(
        med(const MedicationDraft(name: 'M', fixedTz: 'Europe/Berlin')),
        _invalid('fixed_tz'),
      );
      await expectLater(
        med(const MedicationDraft(name: 'M', tzMode: 'utc')),
        _invalid('tz_mode'),
      );
    });

    test('stock: 0..999999999.999, at most 3 decimals', () async {
      for (final ok in ['0', '12.5', '999999999.999']) {
        await med(MedicationDraft(name: 'M', stockCount: ok));
      }
      for (final bad in ['-1', '1.2345', '1000000000', 'ten', '1e3']) {
        await expectLater(
          med(MedicationDraft(name: 'M', stockCount: bad)),
          _invalid('stock_count'),
        );
      }
    });

    test('low_stock_days 0..365 and privacy values', () async {
      await med(const MedicationDraft(name: 'M', lowStockDays: 0));
      await med(const MedicationDraft(name: 'M', lowStockDays: 365));
      await expectLater(
        med(const MedicationDraft(name: 'M', lowStockDays: 366)),
        _invalid('low_stock_days'),
      );
      await expectLater(
        med(const MedicationDraft(name: 'M', lowStockDays: -1)),
        _invalid('low_stock_days'),
      );
      await expectLater(
        med(const MedicationDraft(name: 'M', privacy: 'public')),
        _invalid('privacy'),
      );
    });
  });

  group('dose events', () {
    test('at may be at most 10 minutes ahead; note <= 1000', () async {
      final medication = await med(const MedicationDraft(name: 'M'));
      await env.doseEvents.record(
        medicationId: medication,
        type: DoseEventType.taken,
        at: env.clock.now.add(const Duration(minutes: 10)),
        note: 'n' * 1000,
      );
      await expectLater(
        env.doseEvents.record(
          medicationId: medication,
          type: DoseEventType.taken,
          at: env.clock.now.add(const Duration(minutes: 10, seconds: 1)),
        ),
        _invalid('at'),
      );
      await expectLater(
        env.doseEvents.record(
          medicationId: medication,
          type: DoseEventType.skipped,
          at: env.clock.now,
          note: 'n' * 1001,
        ),
        _invalid('note'),
      );
    });
  });
}
