import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../../data/repositories/local_writer.dart';
import '../../data/repositories/medications_repository.dart';
import '../auth/auth_session.dart';
import '../doses/dose_providers.dart';
import '../doses/scheduled_doses.dart';

/// A live medication of the self profile by id (null once deleted).
final medicationByIdProvider =
    Provider.family<AsyncValue<MedicationRow?>, String>((ref, id) {
  return ref.watch(selfMedicationsProvider).whenData(
        (medications) =>
            medications.where((medication) => medication.id == id).firstOrNull,
      );
});

/// Live schedules of a medication with parsed rules.
final medicationSchedulesProvider =
    StreamProvider.family<List<ParsedSchedule>, String>((ref, medicationId) {
  return ref
      .watch(schedulesRepositoryProvider)
      .watchForMedication(medicationId)
      .map(parseSchedules);
});

/// Saves and deletes medications of the self profile.
final medicationServiceProvider = Provider<MedicationService>(
  MedicationService.new,
);

/// Medication writes for the screens; each write triggers a sync.
class MedicationService {
  /// Creates the service.
  MedicationService(this._ref);

  final Ref<Object?> _ref;

  MedicationsRepository get _repository =>
      _ref.read(medicationsRepositoryProvider);

  /// Creates a medication of the self profile; returns its id.
  ///
  /// Throws [DataException] `parent_not_found` while the self profile has
  /// not been pulled yet (first sync after sign-in still running).
  Future<String> create(MedicationDraft draft) async {
    final profile = await _ref.read(selfProfileProvider.future);
    if (profile == null) {
      requestSyncFrom(_ref);
      throw const DataException(DataException.parentNotFound);
    }
    final id = await _repository.create(profileId: profile.id, draft: draft);
    requestSyncFrom(_ref);
    return id;
  }

  /// Replaces the editable fields of medication [id].
  Future<void> update(String id, MedicationDraft draft) async {
    await _repository.update(id, draft);
    requestSyncFrom(_ref);
  }

  /// Deletes medication [id] with its schedules (history is kept).
  Future<void> delete(String id) async {
    await _repository.delete(id);
    requestSyncFrom(_ref);
  }
}
