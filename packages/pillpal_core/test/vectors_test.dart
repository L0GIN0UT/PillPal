// Runs every shared vector in spec/schedule-vectors/ against the Dart engine.
// The Python reference implementation runs the same files.
import 'dart:convert';
import 'dart:io';

import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

final Directory vectorsDir = Directory('../../spec/schedule-vectors');

const List<String> requiredFiles = [
  'as_needed.json',
  'course.json',
  'daily.json',
  'dst.json',
  'interval.json',
  'invalid.json',
  'timezones.json',
  'weekdays.json',
];

String fileName(FileSystemEntity entity) => entity.uri.pathSegments.last;

List<File> vectorFiles() {
  final files = <File>[];
  for (final entity in vectorsDir.listSync()) {
    final name = fileName(entity);
    if (entity is File && name.endsWith('.json') && name != 'schema.json') {
      files.add(entity);
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

String formatInstant(DateTime instant) {
  final utc = instant.toUtc();
  final date = LocalDate(utc.year, utc.month, utc.day);
  final hh = utc.hour.toString().padLeft(2, '0');
  final mm = utc.minute.toString().padLeft(2, '0');
  final ss = utc.second.toString().padLeft(2, '0');
  return '${date}T$hh:$mm:${ss}Z';
}

Map<String, Object?> occurrenceJson(Occurrence occurrence) {
  return {
    'key': occurrence.key,
    'at_utc': formatInstant(occurrence.atUtc),
    'dose_amount': occurrence.doseAmount,
    'dose_unit': occurrence.doseUnit,
  };
}

void runValidCase(Map<String, Object?> vector) {
  final rule = ScheduleRule.fromJson(vector['rule']);
  final window = vector['window'] as Map<String, Object?>;
  final occurrences = expand(
    rule,
    scheduleId: vector['schedule_id'] as String,
    tz: vector['tz'] as String,
    start: DateTime.parse(window['from'] as String),
    end: DateTime.parse(window['to'] as String),
  );
  final actual = occurrences.map(occurrenceJson).toList();
  expect(actual, equals(vector['expected']));
}

void runInvalidCase(Map<String, Object?> vector) {
  expect(
    () => ScheduleRule.fromJson(vector['rule']),
    throwsA(isA<RuleValidationError>()),
  );
}

void main() {
  final files = vectorFiles();
  var total = 0;

  test('all required vector files are present', () {
    final names = files.map(fileName).toSet();
    expect(names, containsAll(requiredFiles));
  });

  for (final file in files) {
    final name = fileName(file);
    final data = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final cases = data['cases'] as List<Object?>;
    total += cases.length;
    group(name, () {
      for (final item in cases) {
        final vector = item as Map<String, Object?>;
        final caseName = vector['name'] as String;
        if (name == 'invalid.json') {
          test(caseName, () => runInvalidCase(vector));
        } else {
          test(caseName, () => runValidCase(vector));
          test('$caseName (canonical round trip)', () {
            final rule = ScheduleRule.fromJson(vector['rule']);
            final Object? canonical = jsonDecode(jsonEncode(rule.toJson()));
            final again = ScheduleRule.fromJson(canonical);
            expect(again.toJson(), equals(rule.toJson()));
          });
        }
      }
    });
  }

  test('at least 30 vectors', () {
    expect(total, greaterThanOrEqualTo(30));
  });
}
