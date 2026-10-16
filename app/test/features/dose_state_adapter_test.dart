import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/dose_event_mapping.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/reminders/reminder_inputs.dart';
import 'package:pillpal_core/pillpal_core.dart';

// The app reads dose state through pillpal_core (docs/spec/dose-state.md);
// the rule itself is covered by the shared vectors there. These tests pin
// the adapters.

DoseEventRow _row(
  String id,
  String type,
  int minute, {
  String? key = 'k',
  String? target,
  int? snoozeUntilMinute,
}) {
  int at(int m) => DateTime.utc(2026, 10, 17, 4, m).microsecondsSinceEpoch;
  return DoseEventRow(
    id: id,
    profileId: 'p',
    medicationId: 'm',
    eventType: type,
    at: at(minute),
    occurrenceKey: key,
    targetEventId: target,
    snoozeUntil: snoozeUntilMinute == null ? null : at(snoozeUntilMinute),
  );
}

void main() {
  test('a stored event maps to the contract event', () {
    final event = doseEventOf(_row('s', 'snoozed', 5, snoozeUntilMinute: 20));
    expect(event?.type, DoseEventType.snoozed);
    expect(event?.at, DateTime.utc(2026, 10, 17, 4, 5));
    expect(event?.snoozeUntil, DateTime.utc(2026, 10, 17, 4, 20));
    expect(event?.occurrenceKey, 'k');
  });

  test('events of an unknown type are dropped', () {
    expect(doseEventsOf([_row('a', 'pending', 1)]), isEmpty);
  });

  test('missed starts exactly at the due instant plus the grace', () {
    final due = DateTime.utc(2026, 10, 16, 8);
    final edge = due.add(DoseTiming.missedGrace);
    expect(
      doseStatus(null, due, edge.subtract(const Duration(microseconds: 1))),
      DoseStatus.pending,
    );
    expect(doseStatus(null, due, edge), DoseStatus.missed);
  });

  test('an undo without a key still cancels its target', () {
    final states = occurrenceStates([
      _row('a', 'taken', 1),
      _row('b', 'undo', 2, key: null, target: 'a'),
    ]);
    expect(states.handled, isEmpty);
  });

  test('the effective mark ignores the order of the rows', () {
    final rows = [_row('a', 'taken', 1), _row('b', 'skipped', 1)];
    expect(effectiveMark(rows)?.eventId, 'b');
    expect(effectiveMark(rows.reversed)?.eventId, 'b');
  });
}
