import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/repositories/schedule_rows.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'test_env.dart';

// Two devices splitting the same schedule on the same day must create the
// same row (ADR 0006 §9), so the id is derived, not random.

Map<String, Object?> _continued(String time) =>
    {...dailyRule(time: time), 'start_date': '2026-10-16'};

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  test('the id depends on the schedule and the split date only', () {
    final a = splitScheduleId('s-1', LocalDate(2026, 10, 15));

    expect(splitScheduleId('s-1', LocalDate(2026, 10, 15)), a);
    expect(splitScheduleId('s-1', LocalDate(2026, 10, 16)), isNot(a));
    expect(splitScheduleId('s-2', LocalDate(2026, 10, 15)), isNot(a));
    expect(
      a,
      matches(RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
        r'[0-9a-f]{12}$',
      )),
      reason: 'a UUID v5',
    );
  });

  test('a split creates the schedule with the derived id', () async {
    final ids = await env.seedLocal();

    final next = await env.schedules.split(
      ids.schedule,
      endDate: LocalDate(2026, 10, 15),
      rule: _continued('09:00'),
    );

    expect(next, splitScheduleId(ids.schedule, LocalDate(2026, 10, 15)));
  });

  test('repeating the same split updates the row instead of adding one',
      () async {
    final ids = await env.seedLocal();
    final end = LocalDate(2026, 10, 15);
    final first = await env.schedules.split(
      ids.schedule,
      endDate: end,
      rule: _continued('09:00'),
    );

    final second = await env.schedules.split(
      ids.schedule,
      endDate: end,
      rule: _continued('10:00'),
    );

    expect(second, first);
    final live = await env.schedules.watchForMedication(ids.medication).first;
    expect(live, hasLength(2));
    final rule = jsonDecode((await env.schedules.find(first))!.rule)
        as Map<String, Object?>;
    expect(
      ((rule['times']! as List<Object?>).single!
          as Map<String, Object?>)['time'],
      '10:00',
    );
  });

  test('a tombstone with the derived id is never revived: a random id is used',
      () async {
    final ids = await env.seedLocal();
    final end = LocalDate(2026, 10, 15);
    final derived = splitScheduleId(ids.schedule, end);
    final first = await env.schedules.split(
      ids.schedule,
      endDate: end,
      rule: _continued('09:00'),
    );
    expect(first, derived);
    await env.schedules.delete(first);

    final again = await env.schedules.split(
      ids.schedule,
      endDate: end,
      rule: _continued('11:00'),
    );

    expect(again, isNot(derived));
    expect((await env.schedules.find(derived))!.deletedAt, isNotNull);
    expect((await env.schedules.find(again))!.deletedAt, isNull);
  });
}
