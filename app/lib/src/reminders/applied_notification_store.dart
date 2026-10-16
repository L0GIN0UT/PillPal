import 'package:drift/drift.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../data/db/database.dart';
import 'reminder_settings.dart';

/// Applied notifications kept in drift until they are settled
/// (docs/spec/reminders.md §8).
class AppliedNotificationStore {
  /// Creates a store over [_db].
  AppliedNotificationStore(this._db);

  final AppDatabase _db;

  /// Every retained notification, past ones included.
  Future<List<AppliedNotification>> all() async {
    final rows = await _db.select(_db.appliedNotifications).get();
    return [for (final row in rows) _fromRow(row)];
  }

  /// Forgets [ids].
  Future<void> forget(Iterable<int> ids) async {
    final list = ids.toList();
    if (list.isEmpty) {
      return;
    }
    await (_db.delete(_db.appliedNotifications)
          ..where((row) => row.id.isIn(list)))
        .go();
  }

  /// Stores [applied] (replacing rows with the same id).
  Future<void> upsert(Iterable<AppliedNotification> applied) async {
    await _db.batch((batch) {
      batch.insertAllOnConflictUpdate(
        _db.appliedNotifications,
        [for (final item in applied) _toRow(item)],
      );
    });
  }

  /// Forgets every applied notification.
  Future<void> clear() async {
    await _db.delete(_db.appliedNotifications).go();
  }

  /// Forgets notifications that fired before [cutoff]; they are no longer
  /// tracked (and their ids become free).
  Future<void> forgetOlderThan(DateTime cutoff) async {
    final micros = cutoff.toUtc().microsecondsSinceEpoch;
    await (_db.delete(_db.appliedNotifications)
          ..where((row) => row.fireAt.isSmallerThanValue(micros)))
        .go();
  }

  AppliedNotification _fromRow(AppliedNotificationRow row) =>
      AppliedNotification(
        NotificationRequest(
          id: row.id,
          occurrenceKey: row.occurrenceKey,
          medicationId: row.medicationId,
          scheduleId: row.scheduleId,
          fireAtUtc:
              DateTime.fromMicrosecondsSinceEpoch(row.fireAt, isUtc: true),
          repeatIndex: row.repeatIndex,
          level: reminderLevelFromName(row.level),
          isSnooze: row.isSnooze,
        ),
        displayFingerprint: row.displayFingerprint,
        scheduleFingerprint: row.scheduleFingerprint,
      );

  AppliedNotificationRow _toRow(AppliedNotification applied) {
    final request = applied.request;
    return AppliedNotificationRow(
      id: request.id,
      occurrenceKey: request.occurrenceKey,
      medicationId: request.medicationId,
      scheduleId: request.scheduleId,
      fireAt: request.fireAtUtc.microsecondsSinceEpoch,
      repeatIndex: request.repeatIndex,
      level: request.level.name,
      isSnooze: request.isSnooze,
      displayFingerprint: applied.displayFingerprint,
      scheduleFingerprint: applied.scheduleFingerprint,
    );
  }
}
