import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../../data/repositories/medications_repository.dart';
import '../auth/auth_session.dart';
import '../common/local_time.dart';
import '../doses/dose_providers.dart';
import 'stock_level.dart';

/// Dose events recorded after [from] (the earliest stock baseline).
final _eventsAfterProvider = StreamProvider.autoDispose
    .family<List<DoseEventRow>, DateTime>(
  (ref, from) => ref.watch(doseEventsRepositoryProvider).watchAfter(from),
);

/// The stock of every self-profile medication by id (TZ §2.4), recomputed
/// when medications, schedules, dose events or the date change.
final stockLevelsProvider =
    Provider.autoDispose<AsyncValue<Map<String, StockLevel>>>((ref) {
  final today = ref.watch(todayDateProvider);
  final medications = ref.watch(selfMedicationsProvider);
  final schedules = ref.watch(parsedSchedulesProvider);
  final rows = medications.valueOrNull;
  if (rows == null) {
    return medications.whenData((_) => const {});
  }
  DateTime? earliest;
  for (final medication in rows) {
    final baseline = stockBaseline(medication);
    if (baseline != null &&
        (earliest == null || baseline.isBefore(earliest))) {
      earliest = baseline;
    }
  }
  final from = earliest;
  if (from == null) {
    return AsyncData({
      for (final medication in rows) medication.id: const StockNotTracked(),
    });
  }
  return combine3(
    medications,
    schedules,
    ref.watch(_eventsAfterProvider(from)),
    (medications, schedules, events) => {
      for (final medication in medications)
        medication.id: computeStock(
          medication: medication,
          schedules: [
            for (final schedule in schedules)
              if (schedule.row.medicationId == medication.id) schedule,
          ],
          events: events,
          today: today,
        ),
    },
  );
});

/// The stock of medication [id]; [StockNotTracked] until known.
final stockLevelProvider =
    Provider.autoDispose.family<StockLevel, String>((ref, id) {
  final levels = ref.watch(stockLevelsProvider).valueOrNull;
  return levels?[id] ?? const StockNotTracked();
});

/// Stock writes for the screens; each write triggers a sync.
final stockActionsProvider = Provider<StockActions>(StockActions.new);

/// "Пополнить запас": a freshly counted stock becomes the new baseline.
class StockActions {
  /// Creates the actions.
  StockActions(this._ref);

  final Ref<Object?> _ref;

  /// Sets the stock of medication [id] to [count] (a decimal string).
  Future<void> setStock(String id, String count) async {
    await _ref.read(medicationsRepositoryProvider).setStock(id, count);
    requestSyncFrom(_ref);
  }
}
