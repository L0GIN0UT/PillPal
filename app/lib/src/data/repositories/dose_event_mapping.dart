import 'package:pillpal_core/pillpal_core.dart';

import '../db/database.dart';

/// The dose-state view of a stored event (docs/spec/dose-state.md §1.2), or
/// null for a type the contract does not know.
DoseEvent? doseEventOf(DoseEventRow row) {
  final type = DoseEventType.fromWire(row.eventType);
  if (type == null) {
    return null;
  }
  final until = row.snoozeUntil;
  return DoseEvent(
    id: row.id,
    type: type,
    at: DateTime.fromMicrosecondsSinceEpoch(row.at, isUtc: true),
    occurrenceKey: row.occurrenceKey,
    targetEventId: row.targetEventId,
    snoozeUntil: until == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(until, isUtc: true),
  );
}

/// [doseEventOf] of every row with a known type.
List<DoseEvent> doseEventsOf(Iterable<DoseEventRow> rows) {
  final events = <DoseEvent>[];
  for (final row in rows) {
    final event = doseEventOf(row);
    if (event != null) {
      events.add(event);
    }
  }
  return events;
}
