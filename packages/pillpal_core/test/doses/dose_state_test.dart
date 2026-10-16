// Unit tests of the dose-state port beyond the shared vectors.
import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

const String key = 'sched-t01/2026-10-17T08:00';
const String otherKey = 'sched-t01/2026-10-18T08:00';

DateTime at(int minute) => DateTime.utc(2026, 10, 17, 4, minute);

DoseEvent event(
  String id,
  DoseEventType type,
  int minute, {
  String? occurrenceKey = key,
  String? target,
  int? snoozeUntilMinute,
}) {
  return DoseEvent(
    id: id,
    type: type,
    at: at(minute),
    occurrenceKey: occurrenceKey,
    targetEventId: target,
    snoozeUntil: snoozeUntilMinute == null ? null : at(snoozeUntilMinute),
  );
}

void main() {
  test('wire names round trip and unknown names are null', () {
    for (final type in DoseEventType.values) {
      expect(DoseEventType.fromWire(type.wire), type);
    }
    expect(DoseEventType.fromWire('pending'), isNull);
  });

  test('a snooze without snooze_until is ignored', () {
    final events = [
      event('evt-s1', DoseEventType.snoozed, 1, snoozeUntilMinute: 10),
      event('evt-s2', DoseEventType.snoozed, 2),
    ];
    final state = occurrenceStateOf(events, key);
    expect(state.snoozeUntil, at(10));
  });

  test('an undo without a target cancels nothing', () {
    final events = [
      event('evt-a', DoseEventType.taken, 1),
      event('evt-b', DoseEventType.undo, 2),
    ];
    final state = occurrenceStateOf(events, key);
    expect(state.mark?.eventId, 'evt-a');
  });

  test('instants are compared as moments across zone flags', () {
    final local = DoseEvent(
      id: 'evt-a',
      type: DoseEventType.taken,
      at: DateTime.fromMicrosecondsSinceEpoch(at(3).microsecondsSinceEpoch),
      occurrenceKey: key,
    );
    final state = summarizeEvents([
      event('evt-b', DoseEventType.skipped, 2),
      local,
    ]);
    expect(state.mark?.eventId, 'evt-a');
  });

  test('a negative grace is rejected', () {
    const state = OccurrenceState();
    expect(
      () => state.isMissed(
        occurrenceAt: at(0),
        now: at(30),
        grace: const Duration(minutes: -1),
      ),
      throwsArgumentError,
    );
  });

  test('states by key have entries only for marked or snoozed keys', () {
    const third = 'sched-t01/2026-10-19T08:00';
    final states = occurrenceStatesByKey([
      event('evt-a', DoseEventType.taken, 1),
      event(
        'evt-b',
        DoseEventType.snoozed,
        2,
        occurrenceKey: otherKey,
        snoozeUntilMinute: 20,
      ),
      event('evt-c', DoseEventType.taken, 3, occurrenceKey: third),
      event(
        'evt-d',
        DoseEventType.undo,
        4,
        occurrenceKey: third,
        target: 'evt-c',
      ),
      event('evt-e', DoseEventType.taken, 5, occurrenceKey: null),
    ]);
    expect(states.keys.toSet(), {key, otherKey});
    expect(states[key]?.mark?.eventId, 'evt-a');
    expect(states[otherKey]?.mark, isNull);
    expect(states[otherKey]?.snoozeUntil, at(20));
  });

  test('an undo without a key still cancels its target', () {
    final states = occurrenceStatesByKey([
      event('evt-a', DoseEventType.taken, 1),
      event(
        'evt-b',
        DoseEventType.undo,
        2,
        occurrenceKey: null,
        target: 'evt-a',
      ),
    ]);
    expect(states, isEmpty);
  });

  test('states are values', () {
    final first = summarizeEvents([event('evt-a', DoseEventType.taken, 1)]);
    final second = summarizeEvents([event('evt-a', DoseEventType.taken, 1)]);
    expect(first, second);
    expect(first.hashCode, second.hashCode);
  });
}
