import 'package:drift/drift.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../db/database.dart';

/// The query behind `DoseEventsRepository.watchForDays`, also used where no
/// repository exists (the home-screen widget refresh of a background
/// notification action).
Selectable<DoseEventRow> selectDoseEventsForDays(
  AppDatabase db, {
  required Iterable<String> scheduleIds,
  required LocalDate firstDay,
  required LocalDate lastDay,
  required DateTime from,
  required DateTime to,
}) {
  // Keys are `{schedule_id}/{YYYY-MM-DD}T{HH:MM}`, so one schedule's keys
  // of a date range are one lexicographic range.
  final upper = lastDay.addDays(1);
  return db.select(db.doseEvents)
    ..where((row) {
      var condition = row.occurrenceKey.isNull() &
          row.at.isBiggerOrEqualValue(from.toUtc().microsecondsSinceEpoch) &
          (row.at.isSmallerThanValue(to.toUtc().microsecondsSinceEpoch) |
              row.eventType.equals(DoseEventType.undo.wire));
      for (final id in scheduleIds) {
        condition = condition |
            (row.occurrenceKey.isBiggerOrEqualValue('$id/$firstDay') &
                row.occurrenceKey.isSmallerThanValue('$id/$upper'));
      }
      return condition;
    })
    ..orderBy([(row) => OrderingTerm.asc(row.at)]);
}
