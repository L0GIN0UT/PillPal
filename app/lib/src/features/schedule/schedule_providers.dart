import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/repositories/schedules_repository.dart';
import '../auth/auth_session.dart';
import '../doses/scheduled_doses.dart';
import '../medications/medication_providers.dart';

/// A live schedule of [ScheduleKey.medicationId] by id (null when missing).
final scheduleByIdProvider =
    Provider.family<AsyncValue<ParsedSchedule?>, ScheduleKey>((ref, key) {
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

  /// Creates a schedule of [medicationId], or replaces the rule of
  /// [scheduleId]. [rule] is validated by the repository.
  Future<void> save({
    required String medicationId,
    required String? scheduleId,
    required Map<String, Object?> rule,
  }) async {
    if (scheduleId == null) {
      await _repository.create(medicationId: medicationId, rule: rule);
    } else {
      await _repository.update(scheduleId, rule);
    }
    requestSyncFrom(_ref);
  }

  /// Deletes schedule [scheduleId] (its dose history stays).
  Future<void> delete(String scheduleId) async {
    await _repository.delete(scheduleId);
    requestSyncFrom(_ref);
  }
}
