import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal/src/features/stock/stock_level.dart';
import 'package:pillpal_core/pillpal_core.dart';

// Stock = baseline count - doses taken after the baseline instant
// (docs/adr/0004-stock-tracking.md). Synthetic data only.

final DateTime _baseline = DateTime.utc(2026, 10, 10, 9);
final LocalDate _today = LocalDate(2026, 10, 16);

MedicationRow _medication({
  String? stock = '30',
  String? unit = 'tablet',
  int? lowDays,
  DateTime? setAt,
  int conflictKey = 1,
}) =>
    MedicationRow(
      id: 'm',
      profileId: 'p',
      name: 'Med',
      tzMode: 'local',
      privacy: 'shared',
      redacted: false,
      clientUpdatedAt: conflictKey,
      updatedByDevice: 'd',
      stockCount: stock,
      stockUnit: unit,
      lowStockDays: lowDays,
      stockSetAt: (setAt ?? _baseline).microsecondsSinceEpoch,
    );

ParsedSchedule _schedule(
  String id,
  Map<String, Object?> rule, {
  String medicationId = 'm',
}) =>
    ParsedSchedule(
      ScheduleRow(
        id: id,
        medicationId: medicationId,
        rule: '{}',
        redacted: false,
        clientUpdatedAt: 1,
        updatedByDevice: 'd',
      ),
      ScheduleRule.fromJson({
        'v': 1,
        'kind': 'daily',
        'start_date': '2026-10-01',
        'end_date': null,
        ...rule,
      }),
    );

Map<String, Object?> _slots(Map<String, String> doses,
        {String unit = 'tablet'}) =>
    {
      'times': [
        for (final entry in doses.entries)
          {
            'time': entry.key,
            'dose': {'amount': entry.value, 'unit': unit},
          },
      ],
    };

var _seq = 0;

DoseEventRow _event(
  String type,
  DateTime at, {
  String? key,
  String? target,
  String? id,
  String medicationId = 'm',
}) =>
    DoseEventRow(
      id: id ?? 'e${_seq++}',
      profileId: 'p',
      medicationId: medicationId,
      eventType: type,
      at: at.microsecondsSinceEpoch,
      occurrenceKey: key,
      targetEventId: target,
    );

StockLevel _compute(
  MedicationRow medication,
  List<ParsedSchedule> schedules,
  List<DoseEventRow> events,
) =>
    computeStock(
      medication: medication,
      schedules: schedules,
      events: events,
      today: _today,
    );

StockKnown _known(StockLevel level) {
  expect(level, isA<StockKnown>());
  return level as StockKnown;
}

void main() {
  final daily = _schedule('s1', _slots({'08:00': '1', '20:00': '0.5'}));
  DateTime day(int d, [int hour = 10]) => DateTime.utc(2026, 10, d, hour);

  test('decimal amounts are exact thousandths', () {
    expect(parseMilli('12.5'), 12500);
    expect(parseMilli('0.125'), 125);
    expect(parseMilli('30'), 30000);
    expect(parseMilli('1.2345'), isNull);
    expect(parseMilli('-1'), isNull);
    expect(formatMilli(12500), '12.5');
    expect(formatMilli(30000), '30');
    expect(formatMilli(125), '0.125');
  });

  test('no count means not tracked', () {
    expect(_compute(_medication(stock: null), [daily], const []),
        isA<StockNotTracked>());
  });

  test('taken doses after the baseline are subtracted with their slot dose',
      () {
    final level = _known(_compute(_medication(), [
      daily
    ], [
      // Before the baseline: already counted in the 30.
      _event('taken', day(9), key: 's1/2026-10-09T08:00'),
      _event('taken', day(11), key: 's1/2026-10-11T08:00'),
      _event('taken', day(11, 20), key: 's1/2026-10-11T20:00'),
      _event('taken', day(12), key: 's1/2026-10-12T08:00'),
    ]));
    expect(level.remainingMilli, 27500);
    expect(level.remaining, '27.5');
    expect(level.unit, DoseUnit.tablet);
    // 1.5 tablets a day: 18 whole days.
    expect(level.daysLeft, 18);
  });

  test('undone and skipped doses are not subtracted', () {
    final taken = _event('taken', day(11), key: 's1/2026-10-11T08:00');
    final level = _known(_compute(_medication(), [
      daily
    ], [
      taken,
      _event('undo', day(11, 11), target: taken.id),
      _event('skipped', day(12), key: 's1/2026-10-12T08:00'),
      _event('snoozed', day(13), key: 's1/2026-10-13T08:00'),
      // Taken, then corrected to skipped: the effective mark is "skipped".
      _event('taken', day(14), key: 's1/2026-10-14T20:00'),
      _event('skipped', day(14, 21), key: 's1/2026-10-14T20:00'),
    ]));
    expect(level.remainingMilli, 30000);
  });

  test('a dose marked twice (taken, undo, taken) counts once', () {
    final first = _event('taken', day(11), key: 's1/2026-10-11T08:00');
    final level = _known(_compute(_medication(), [
      daily
    ], [
      first,
      _event('undo', day(11, 11), target: first.id),
      _event('taken', day(11, 12), key: 's1/2026-10-11T08:00'),
    ]));
    expect(level.remainingMilli, 29000);
  });

  test('a refill moves the baseline: earlier doses no longer count', () {
    final events = [
      _event('taken', day(11), key: 's1/2026-10-11T08:00'),
      _event('taken', day(15), key: 's1/2026-10-15T08:00'),
    ];
    final refilled = _medication(stock: '60', setAt: day(14));
    expect(_known(_compute(refilled, [daily], events)).remainingMilli, 59000);
  });

  test('rows without stock_set_at fall back to the conflict key', () {
    final legacy = MedicationRow(
      id: 'm',
      profileId: 'p',
      name: 'Med',
      tzMode: 'local',
      privacy: 'shared',
      redacted: false,
      clientUpdatedAt: day(12).microsecondsSinceEpoch,
      updatedByDevice: 'd',
      stockCount: '10',
      stockUnit: 'tablet',
    );
    expect(stockBaselineOf(legacy), day(12));
    final level = _known(_compute(legacy, [
      daily
    ], [
      _event('taken', day(11), key: 's1/2026-10-11T08:00'),
      _event('taken', day(13), key: 's1/2026-10-13T08:00'),
    ]));
    expect(level.remainingMilli, 9000);
  });

  test('several schedules add up, ended ones still subtract', () {
    final morning = _schedule('s1', _slots({'08:00': '1'}));
    final weekly = _schedule(
      's2',
      {
        'kind': 'weekdays',
        'weekdays': [1, 3, 5, 7],
        ..._slots({'21:00': '2'}),
      },
    );
    final ended = _schedule(
      's3',
      {
        'end_date': '2026-10-12',
        ..._slots({'12:00': '3'})
      },
    );
    final level = _known(_compute(_medication(), [
      morning,
      weekly,
      ended
    ], [
      _event('taken', day(11), key: 's1/2026-10-11T08:00'),
      _event('taken', day(11, 21), key: 's2/2026-10-11T21:00'),
      _event('taken', day(12), key: 's3/2026-10-12T12:00'),
      // Another medication's event never counts.
      _event('taken', day(12), key: 's9/2026-10-12T08:00', medicationId: 'x'),
    ]));
    expect(level.remainingMilli, 30000 - 1000 - 2000 - 3000);
    // Running today: 1/day + 2 x 4/7 per day = 2.142... -> 24 / 2.14 = 11.
    expect(level.daysLeft, 11);
  });

  test('future and ended schedules do not count for days left', () {
    final future = _schedule('s1', {
      'start_date': '2026-11-01',
      ..._slots({'08:00': '1'}),
    });
    final level = _known(_compute(_medication(), [future], const []));
    expect(level.remainingMilli, 30000);
    expect(level.daysLeft, isNull);
  });

  test('a unit mismatch cannot be computed', () {
    final ml = _schedule('s1', _slots({'08:00': '5'}, unit: 'ml'));
    expect(
      _compute(_medication(), [ml], const []),
      isA<StockUnknown>().having(
        (level) => level.problem,
        'problem',
        StockProblem.unitMismatch,
      ),
    );
    final level = _compute(_medication(), [
      ml.endedCopy()
    ], [
      _event('taken', day(11), key: 's1/2026-10-11T08:00'),
    ]);
    expect(
      (level as StockUnknown).problem,
      StockProblem.unitMismatch,
    );
    expect(
      (_compute(_medication(unit: 'шт'), [daily], const []) as StockUnknown)
          .problem,
      StockProblem.unknownUnit,
    );
  });

  test('as-needed intakes use the slot dose or one piece', () {
    final asNeeded =
        _schedule('s1', {'kind': 'as_needed', 'times': <Object>[]});
    final intakes = [
      _event('taken', day(11)),
      _event('taken', day(12)),
    ];
    final undo = _event('undo', day(12, 11), target: intakes.last.id);
    final pieces = _known(
      _compute(_medication(), [asNeeded], [...intakes, undo]),
    );
    expect(pieces.remainingMilli, 29000);
    expect(pieces.daysLeft, isNull);

    final withDose = _schedule('s2', _slots({'08:00': '2'}));
    expect(
      _known(_compute(_medication(), [asNeeded, withDose], intakes))
          .remainingMilli,
      26000,
    );
    expect(
      (_compute(_medication(unit: 'ml'), [asNeeded], intakes) as StockUnknown)
          .problem,
      StockProblem.unknownIntakeDose,
    );
  });

  test('more taken than counted shows zero and zero days', () {
    final level = _known(_compute(_medication(stock: '1'), [
      daily
    ], [
      _event('taken', day(11), key: 's1/2026-10-11T08:00'),
      _event('taken', day(11, 20), key: 's1/2026-10-11T20:00'),
    ]));
    expect(level.remainingMilli, -500);
    expect(level.remaining, '0');
    expect(level.daysLeft, 0);
  });

  test('low stock at or below the threshold (default 7 days)', () {
    StockKnown days(int value) => StockKnown(
          remainingMilli: 1000,
          unit: DoseUnit.tablet,
          daysLeft: value,
        );
    expect(isLowStock(_medication(), days(7)), isTrue);
    expect(isLowStock(_medication(), days(8)), isFalse);
    expect(isLowStock(_medication(lowDays: 3), days(4)), isFalse);
    expect(isLowStock(_medication(), const StockNotTracked()), isFalse);
    expect(
      isLowStock(
        _medication(),
        const StockKnown(
            remainingMilli: 0, unit: DoseUnit.tablet, daysLeft: null),
      ),
      isFalse,
    );
  });

  test('consumption is an exact fraction per period', () {
    ScheduleRule rule(Map<String, Object?> extra) => _schedule('s', {
          ..._slots({'08:00': '2'}),
          ...extra,
        }).rule;
    expect(periodConsumption(rule({'kind': 'daily'})), (milli: 2000, days: 1));
    expect(
      periodConsumption(rule({'kind': 'interval_days', 'interval_days': 4})),
      (milli: 2000, days: 4),
    );
    expect(
      periodConsumption(rule({
        'kind': 'weekdays',
        'weekdays': [1, 3, 5],
      })),
      (milli: 6000, days: 7),
    );
    expect(
      periodConsumption(rule({'kind': 'as_needed', 'times': <Object>[]})),
      (milli: 0, days: 1),
    );
    expect(
      consumptionRate([
        rule({'kind': 'daily'}),
        rule({'kind': 'interval_days', 'interval_days': 3}),
      ]),
      (milli: 8000, days: 3),
    );
  });

  test('1 tablet Mon-Fri with 5 left lasts 7 days', () {
    final workdays = _schedule('s1', {
      'kind': 'weekdays',
      'weekdays': [1, 2, 3, 4, 5],
      ..._slots({'08:00': '1'}),
    });
    expect(
      _known(_compute(_medication(stock: '5'), [workdays], const [])).daysLeft,
      7,
    );
  });

  test('every other day: days left without rounding drift', () {
    final everyOther = _schedule('s1', {
      'kind': 'interval_days',
      'interval_days': 2,
      ..._slots({'08:00': '1'}),
    });
    int? days(String stock) =>
        _known(_compute(_medication(stock: stock), [everyOther], const []))
            .daysLeft;
    expect(days('13'), 26);
    expect(days('15'), 30);
    final everyThird = _schedule('s1', {
      'kind': 'interval_days',
      'interval_days': 3,
      ..._slots({'08:00': '0.1'}),
    });
    // 0.3 tablets / 0.1 per 3 days = exactly 9 days (2.9999... in doubles).
    expect(
      _known(_compute(_medication(stock: '0.3'), [everyThird], const []))
          .daysLeft,
      9,
    );
  });

  test('a dose taken from a deleted schedule makes the stock unknown', () {
    final level = _compute(_medication(), [
      daily
    ], [
      _event('taken', day(11), key: 's1/2026-10-11T08:00'),
      _event('taken', day(12), key: 'gone/2026-10-12T08:00'),
    ]);
    expect(
      (level as StockUnknown).problem,
      StockProblem.unknownSchedule,
    );
    // Before the baseline it does not matter: it is in the count already.
    expect(
      _compute(_medication(), [
        daily
      ], [
        _event('taken', day(9), key: 'gone/2026-10-09T08:00'),
      ]),
      isA<StockKnown>(),
    );
  });

  test('an undo cancels its dose', () {
    final taken = _event('taken', day(11), key: 's1/2026-10-11T08:00');
    final level = _known(_compute(_medication(), [
      daily
    ], [
      taken,
      _event('undo', day(12), target: taken.id, key: 's1/2026-10-11T08:00'),
    ]));
    expect(level.remainingMilli, 30000);
  });
}

extension on ParsedSchedule {
  /// This schedule ended before the test's today.
  ParsedSchedule endedCopy() => ParsedSchedule(
        row,
        ScheduleRule.fromJson({...rule.toJson(), 'end_date': '2026-10-12'}),
      );
}
