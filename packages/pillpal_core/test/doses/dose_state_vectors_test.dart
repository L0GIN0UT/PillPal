// Runs every shared vector in spec/dose-state-vectors/ against the Dart port.
// The Python reference implementation runs the same files.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

final Directory vectorsDir = Directory('../../spec/dose-state-vectors');

const List<String> requiredFiles = [
  'marks.json',
  'missed.json',
  'snooze.json',
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

DateTime instant(Object? value) => DateTime.parse(value as String);

DateTime? optionalInstant(Object? value) =>
    value == null ? null : instant(value);

DoseEvent eventOf(Map<String, Object?> json) {
  final wire = json['type'] as String;
  return DoseEvent(
    id: json['id'] as String,
    type: DoseEventType.values.firstWhere((type) => type.wire == wire),
    at: instant(json['at']),
    occurrenceKey: json['occurrence_key'] as String?,
    targetEventId: json['target_event_id'] as String?,
    snoozeUntil: optionalInstant(json['snooze_until']),
  );
}

List<List<DoseEvent>> orderings(List<DoseEvent> events) {
  return [
    events,
    events.reversed.toList(),
    List<DoseEvent>.of(events)..shuffle(Random(20261016)),
  ];
}

void expectState(
  OccurrenceState state,
  Map<String, Object?> expected,
  DateTime occurrenceAt,
) {
  final mark = expected['mark'] as Map<String, Object?>?;
  if (mark == null) {
    expect(state.mark, isNull);
  } else {
    final actual = state.mark;
    expect(actual, isNotNull);
    expect(actual?.eventId, mark['event_id']);
    expect(actual?.type.wire, mark['type']);
    expect(actual?.at, instant(mark['at']));
  }
  expect(state.snoozeUntil, optionalInstant(expected['snooze_until']));
  expect(state.dueAt(occurrenceAt), instant(expected['due']));
}

void runCase(Map<String, Object?> vector) {
  final key = vector['occurrence_key'] as String;
  final occurrenceAt = instant(vector['occurrence_at']);
  final expected = vector['expected'] as Map<String, Object?>;
  final rawProbes = vector['missed'] as List<Object?>? ?? const <Object?>[];
  final events = <DoseEvent>[
    for (final item in vector['events'] as List<Object?>)
      eventOf(item as Map<String, Object?>),
  ];

  for (final ordered in orderings(events)) {
    final state = occurrenceStateOf(ordered, key);
    expectState(state, expected, occurrenceAt);
    for (final raw in rawProbes) {
      final probe = raw as Map<String, Object?>;
      final grace = Duration(minutes: probe['grace_minutes'] as int);
      expect(
        state.isMissed(
          occurrenceAt: occurrenceAt,
          now: instant(probe['now']),
          grace: grace,
        ),
        probe['expected'],
        reason: '$probe',
      );
    }
  }

  // Folding every key at once agrees with the keyed fold.
  final single = occurrenceStateOf(events, key);
  final grouped = occurrenceStatesByKey(events)[key];
  if (single.mark == null && single.snoozeUntil == null) {
    expect(grouped, isNull);
  } else {
    expect(grouped, single);
  }

  // Pre-grouped events (the key's own, plus every undo) fold the same way.
  bool isOwnOrUndo(DoseEvent event) =>
      event.occurrenceKey == key || event.type == DoseEventType.undo;
  final own = events.where(isOwnOrUndo).toList();
  expect(summarizeEvents(own), single);
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
        test(vector['name'] as String, () => runCase(vector));
      }
    });
  }

  test('at least 30 vectors', () {
    expect(total, greaterThanOrEqualTo(30));
  });
}
