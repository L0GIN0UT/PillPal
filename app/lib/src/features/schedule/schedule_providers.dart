import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../data/providers.dart';
import '../../data/repositories/local_writer.dart';
import '../../data/repositories/schedules_repository.dart';
import '../auth/auth_session.dart';
import '../doses/scheduled_doses.dart';
import '../medications/medication_providers.dart';
import 'schedule_edit.dart';

/// A live schedule of [ScheduleKey.medicationId] by id (null when missing).
final scheduleByIdProvider = Provider.autoDispose
    .family<AsyncValue<ParsedSchedule?>, ScheduleKey>((ref, key) {
  return ref.watch(medicationSchedulesProvider(key.medicationId)).whenData(
        (schedules) => schedules
            .where((schedule) => schedule.row.id == key.scheduleId)
            .firstOrNull,
      );
});

/// Identifies a schedule of a medication.
typedef ScheduleKey = ({String medicationId, String scheduleId});

/// Saves and deletes schedules.
final scheduleServiceProvider = Provider<ScheduleService>(ScheduleService.new);

/// Schedule writes for the editor; each write triggers a sync.
class ScheduleService {
  /// Creates the service.
  ScheduleService(this._ref);

  final Ref<Object?> _ref;

  SchedulesRepository get _repository => _ref.read(schedulesRepositoryProvider);

  /// Creates a schedule of [medicationId], or saves an edit of [scheduleId]
  /// without touching the past (ADR 0003 §1, §2): a started schedule is
  /// split, one that starts today or later is edited in place.
  ///
  /// Throws [DataException] `invalid_rule` for a rule the engine rejects and
  /// [ScheduleEditException] for an edit ADR 0003 does not allow.
  Future<void> save({
    required String medicationId,
    required String? scheduleId,
    required Map<String, Object?> rule,
  }) async {
    if (scheduleId == null) {
      await _repository.create(medicationId: medicationId, rule: rule);
      requestSyncFrom(_ref);
      return;
    }
    final current = await _repository.find(scheduleId);
    if (current == null || current.deletedAt != null) {
      throw const DataException(DataException.notFound);
    }
    final plan = planScheduleEdit(
      current: current.scheduleRule,
      edited: _parse(rule),
      today: await _medications.todayFor(medicationId),
    );
    switch (plan) {
      case KeepSchedule():
        return;
      case EditInPlace(rule: final edited):
        await _repository.update(scheduleId, edited);
      case SplitSchedule(:final endDate, rule: final continued):
        await _repository.split(scheduleId, endDate: endDate, rule: continued);
    }
    requestSyncFrom(_ref);
  }

  /// Finishes schedule [scheduleId] of [medicationId]: it ends yesterday and
  /// its history stays (ADR 0003 §3).
  Future<void> finish({
    required String medicationId,
    required String scheduleId,
  }) async {
    final today = await _medications.todayFor(medicationId);
    await _repository.end(scheduleId, today.addDays(-1));
    requestSyncFrom(_ref);
  }

  /// Deletes schedule [scheduleId]: its doses no longer count in the history
  /// ("delete with history", ADR 0003 §3).
  Future<void> delete(String scheduleId) async {
    await _repository.delete(scheduleId);
    requestSyncFrom(_ref);
  }

  MedicationService get _medications => _ref.read(medicationServiceProvider);

  static ScheduleRule _parse(Map<String, Object?> rule) {
    try {
      return ScheduleRule.fromJson(rule);
    } on RuleValidationError {
      throw const DataException(DataException.invalidRule);
    }
  }
}
