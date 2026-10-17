import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../../data/repositories/local_writer.dart';
import '../../data/repositories/medications_repository.dart';
import '../auth/auth_session.dart';
import '../common/local_time.dart';
import '../doses/dose_providers.dart';
import '../doses/scheduled_doses.dart';
import '../family/profile_context.dart';

/// A live medication by id (null once deleted), whichever profile it is in:
/// the screens that edit it check the role on its profile.
final medicationByIdProvider =
    StreamProvider.autoDispose.family<MedicationRow?, String>((ref, id) {
  return ref.watch(medicationsRepositoryProvider).watchById(id);
});

/// What the account may do on the profile of medication [id]; null while
/// unknown. Written from the medication's `profile_id`, not from the
/// screen it was opened on.
final medicationAccessProvider =
    Provider.autoDispose.family<AsyncValue<ProfileAccess?>, String>((ref, id) {
  final medication = ref.watch(medicationByIdProvider(id));
  final row = medication.valueOrNull;
  if (row == null) {
    return medication.isLoading ? const AsyncLoading() : const AsyncData(null);
  }
  return ref.watch(profileAccessProvider(row.profileId));
});

/// Live schedules of a medication with parsed rules.
final medicationSchedulesProvider = StreamProvider.autoDispose
    .family<List<ParsedSchedule>, String>((ref, medicationId) {
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

  /// Creates a medication of [profileId] (null: the user's own `self`
  /// profile); returns its id.
  ///
  /// Throws [DataException] `parent_not_found` while the profile has not
  /// been pulled yet (first sync after sign-in still running).
  Future<String> create(MedicationDraft draft, {String? profileId}) async {
    final target =
        profileId ?? (await _ref.read(selfProfileProvider.future))?.id;
    if (target == null) {
      requestSyncFrom(_ref);
      throw const DataException(DataException.parentNotFound);
    }
    final id = await _repository.create(profileId: target, draft: draft);
    requestSyncFrom(_ref);
    return id;
  }

  /// Replaces the editable fields of medication [id].
  Future<void> update(String id, MedicationDraft draft) async {
    await _repository.update(id, draft);
    requestSyncFrom(_ref);
  }

  /// Deletes medication [id] with its schedules: its doses no longer count
  /// in the history ("delete with history", ADR 0003 §3).
  Future<void> delete(String id) async {
    await _repository.delete(id);
    requestSyncFrom(_ref);
  }

  /// Finishes medication [id] ("history is kept", ADR 0003 §3): its running
  /// schedules end yesterday and it moves to the archived section.
  Future<void> finish(String id) async {
    final today = await todayFor(id);
    await _ref.read(schedulesRepositoryProvider).finishMedication(id, today);
    requestSyncFrom(_ref);
  }

  /// The live schedules of medication [id] with parsed rules.
  Future<List<ParsedSchedule>> schedulesOf(String id) async {
    final repository = _ref.read(schedulesRepositoryProvider);
    return parseSchedules(await repository.forMedication(id));
  }

  /// Today in the effective zone of medication [id], the zone its rule dates
  /// are in (docs/spec/schedule.md §3.1); the device zone if it is unknown.
  /// `local` medications of another person's profile follow that profile's
  /// zone (D4).
  Future<LocalDate> todayFor(String id) async {
    final medication = await _repository.find(id);
    final deviceTz = _ref.read(deviceTimeZoneProvider);
    final now = _ref.read(clockProvider)();
    if (medication == null) {
      return localDateOf(now, deviceTz);
    }
    final access =
        await _ref.read(profileAccessProvider(medication.profileId).future);
    final local = access?.localZone(deviceTz) ?? deviceTz;
    return localDateOf(now, effectiveZone(medication, local));
  }
}
