// Runs every shared vector in spec/gtin-vectors/ against the Dart port.
// The Python reference (catalog) and the backend subset run the same files.
import 'dart:convert';
import 'dart:io';

import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

final Directory vectorsDir = Directory('../../spec/gtin-vectors');

List<Map<String, Object?>> loadCases(String fileName) {
  final text = File('${vectorsDir.path}/$fileName').readAsStringSync();
  final data = jsonDecode(text) as Map<String, Object?>;
  return (data['cases'] as List<Object?>).cast<Map<String, Object?>>();
}

String dateOnly(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year.toString().padLeft(4, '0')}-$month-$day';
}

Map<String, Object?> runNormalizeCase(Map<String, Object?> vector) {
  final input = vector['input'] as String;
  try {
    switch (vector['op']) {
      case 'normalize':
        final gtin = normalizeGtin(input);
        return {
          'gtin14': gtin.gtin14,
          'source_length': gtin.sourceLength,
          'classification': gtin.classification.wire,
        };
      case 'gtin14_to_gtin13':
        return {'gtin13': gtin14ToGtin13(input)};
      case 'ndc_to_gtin14':
        return {'gtin14': ndcToGtin14(input)};
      default:
        fail('unknown op ${vector['op']}');
    }
  } on GtinException catch (error) {
    return {'error': error.code.wire};
  }
}

Map<String, Object?> runGs1Case(Map<String, Object?> vector) {
  try {
    final result = parseGs1(vector['input'] as String);
    final expiry = result.expiry;
    return {
      'gtin14': result.gtin.gtin14,
      'classification': result.gtin.classification.wire,
      'expiry': expiry == null ? null : dateOnly(expiry),
      'partial': result.partial,
    };
  } on GtinException catch (error) {
    return {'error': error.code.wire};
  }
}

void main() {
  group('normalize.json', () {
    final cases = loadCases('normalize.json');

    test('has enough cases', () {
      expect(cases.length, greaterThanOrEqualTo(40));
    });

    for (final vector in cases) {
      test(vector['name'] as String, () {
        expect(runNormalizeCase(vector), vector['expected']);
      });
    }
  });

  group('gs1.json', () {
    final cases = loadCases('gs1.json');

    test('has enough cases', () {
      expect(cases.length, greaterThanOrEqualTo(40));
    });

    for (final vector in cases) {
      test(vector['name'] as String, () {
        expect(runGs1Case(vector), vector['expected']);
      });
    }
  });

  group('value types', () {
    test('Gtin is a value', () {
      expect(normalizeGtin('4006381333931'), normalizeGtin('4 006381 333931'));
      expect(
        normalizeGtin('4006381333931').hashCode,
        normalizeGtin('4006-3813-33931').hashCode,
      );
    });

    test('Gs1Result compares the expiry as a moment', () {
      final gtin = normalizeGtin('04607012345677');
      final a = Gs1Result(gtin: gtin, expiry: DateTime.utc(2027, 12, 31));
      final b = Gs1Result(gtin: gtin, expiry: DateTime.utc(2027, 12, 31));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(Gs1Result(gtin: gtin)));
    });

    test('the textual forms carry neither input nor number', () {
      final result = parseGs1('010460701234567710SECRETLOT21SECRET');
      expect(result.toString(), isNot(contains('SECRET')));
      expect(result.toString(), isNot(contains('4607012345677')));
      expect(result.gtin.toString(), isNot(contains('4607012345677')));
      expect(
        () => normalizeGtin('PRIVATE'),
        throwsA(
          isA<GtinException>().having(
            (e) => e.toString(),
            'toString',
            isNot(contains('PRIVATE')),
          ),
        ),
      );
    });

    test('an RCN-8 stays restricted however it is written', () {
      for (final raw in ['02345673', '000002345673', '0000002345673']) {
        expect(
          normalizeGtin(raw).classification,
          GtinClassification.restricted,
        );
      }
    });
  });
}
