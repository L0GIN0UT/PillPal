import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

Map<String, Object?> slot(String time, String amount, [String unit = 'ml']) {
  return {
    'time': time,
    'dose': {'amount': amount, 'unit': unit}
  };
}

Map<String, Object?> rule([Map<String, Object?> overrides = const {}]) {
  return {
    'v': 1,
    'kind': 'daily',
    'start_date': '2026-10-16',
    'times': [slot('08:00', '1', 'tablet')],
    ...overrides,
  };
}

final Matcher throwsRuleError = throwsA(isA<RuleValidationError>());

void main() {
  group('ScheduleRule.fromJson', () {
    test('minimal daily rule', () {
      final parsed = ScheduleRule.fromJson(rule());
      expect(parsed.kind, RuleKind.daily);
      expect(parsed.startDate, LocalDate(2026, 10, 16));
      expect(parsed.endDate, isNull);
      expect(parsed.weekdays, isNull);
      expect(parsed.intervalDays, isNull);
      expect(parsed.times.single.dose.unit, DoseUnit.tablet);
    });

    test('sorts weekdays and slots, normalises amounts', () {
      final json = rule({
        'kind': 'weekdays',
        'weekdays': [7, 1, 3],
        'times': [slot('20:00', '0.50'), slot('08:00', '2.000')],
      });
      final parsed = ScheduleRule.fromJson(json);
      expect(parsed.weekdays, [1, 3, 7]);
      expect(parsed.times.map((s) => s.time), ['08:00', '20:00']);
      expect(parsed.times.map((s) => s.dose.amount), ['2', '0.5']);
    });

    test('canonical JSON omits fields of other kinds', () {
      final json = rule({'weekdays': null, 'interval_days': null});
      final expected = {
        'v': 1,
        'kind': 'daily',
        'start_date': '2026-10-16',
        'end_date': null,
        'times': [slot('08:00', '1', 'tablet')],
      };
      expect(ScheduleRule.fromJson(json).toJson(), equals(expected));
    });

    test('accepts maps with dynamic keys and values', () {
      final json = <dynamic, dynamic>{...rule()};
      expect(ScheduleRule.fromJson(json).kind, RuleKind.daily);
    });

    test('24 slots are allowed, 25 are not', () {
      final slots = <Map<String, Object?>>[];
      for (var h = 0; h < 24; h++) {
        final hh = h.toString().padLeft(2, '0');
        slots.add(slot('$hh:00', '1'));
      }
      final parsed = ScheduleRule.fromJson(rule({'times': slots}));
      expect(parsed.times, hasLength(24));
      final tooMany = rule({
        'times': [...slots, slot('23:30', '1')]
      });
      expect(() => ScheduleRule.fromJson(tooMany), throwsRuleError);
    });

    test('rejects doubles where integers are expected', () {
      expect(() => ScheduleRule.fromJson(rule({'v': 1.0})), throwsRuleError);
      final interval = rule({'kind': 'interval_days', 'interval_days': 2.0});
      expect(() => ScheduleRule.fromJson(interval), throwsRuleError);
    });

    test('rejects non-objects', () {
      expect(() => ScheduleRule.fromJson(null), throwsRuleError);
      expect(() => ScheduleRule.fromJson('rule'), throwsRuleError);
      expect(() => ScheduleRule.fromJson([rule()]), throwsRuleError);
    });
  });

  group('occursOn', () {
    test('course bounds are inclusive', () {
      final parsed = ScheduleRule.fromJson(rule({'end_date': '2026-10-20'}));
      expect(parsed.occursOn(LocalDate(2026, 10, 15)), isFalse);
      expect(parsed.occursOn(LocalDate(2026, 10, 16)), isTrue);
      expect(parsed.occursOn(LocalDate(2026, 10, 20)), isTrue);
      expect(parsed.occursOn(LocalDate(2026, 10, 21)), isFalse);
    });

    test('interval is anchored at start_date', () {
      final json = rule({
        'kind': 'interval_days',
        'interval_days': 3,
        'start_date': '2026-10-01',
      });
      final parsed = ScheduleRule.fromJson(json);
      final hits = <int>[];
      for (var d = 1; d <= 31; d++) {
        if (parsed.occursOn(LocalDate(2026, 10, d))) {
          hits.add(d);
        }
      }
      expect(hits, [1, 4, 7, 10, 13, 16, 19, 22, 25, 28, 31]);
    });
  });

  group('normalizeAmount', () {
    const valid = {
      '1': '1',
      '0.5': '0.5',
      '0.50': '0.5',
      '2.000': '2',
      '100.10': '100.1',
      '999999.999': '999999.999',
    };
    for (final entry in valid.entries) {
      test('${entry.key} -> ${entry.value}', () {
        expect(normalizeAmount(entry.key), entry.value);
      });
    }

    const invalid = ['0', '0.000', '-1', '.5', '5.', '1e3', '01', '1,5', ''];
    for (final raw in invalid) {
      test('rejects "$raw"', () {
        expect(() => normalizeAmount(raw), throwsRuleError);
      });
    }
  });

  group('LocalDate', () {
    test('tryParse', () {
      expect(LocalDate.tryParse('2028-02-29'), LocalDate(2028, 2, 29));
      expect(LocalDate.tryParse('2027-02-29'), isNull);
      expect(LocalDate.tryParse('2026-1-5'), isNull);
      expect(LocalDate.tryParse('2026-10-16T00:00'), isNull);
    });

    test('rejects non-existent dates', () {
      expect(() => LocalDate(2026, 2, 30), throwsArgumentError);
    });

    test('arithmetic and weekday', () {
      final date = LocalDate(2028, 2, 28);
      expect(date.addDays(1), LocalDate(2028, 2, 29));
      expect(date.addDays(2), LocalDate(2028, 3, 1));
      expect(LocalDate(2026, 12, 31).addDays(1), LocalDate(2027, 1, 1));
      expect(LocalDate(1970, 1, 1).epochDay, 0);
      expect(LocalDate(1969, 12, 31).epochDay, -1);
      expect(LocalDate.fromEpochDay(-1), LocalDate(1969, 12, 31));
      expect(LocalDate(2026, 10, 12).weekday, DateTime.monday);
      expect(LocalDate(2026, 10, 18).weekday, DateTime.sunday);
    });

    test('ordering and formatting', () {
      final a = LocalDate(2026, 10, 16);
      final b = LocalDate(2026, 11, 1);
      expect(a.isBefore(b), isTrue);
      expect(b.isAfter(a), isTrue);
      expect(a.compareTo(a), 0);
      expect(a.toString(), '2026-10-16');
    });
  });
}
