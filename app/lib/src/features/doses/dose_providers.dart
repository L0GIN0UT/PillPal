import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../../data/repositories/dose_events_repository.dart';
import '../auth/auth_session.dart';
import 'scheduled_doses.dart';

// UI-side reads over the data layer's repositories (drift streams), shared
// by Today, Medications and History.

/// The user's own profile; null until the first pull delivered it.
final selfProfileProvider = StreamProvider<ProfileRow?>((ref) {
  return ref.watch(profilesRepositoryProvider).watchAll().map((profiles) {
    for (final profile in profiles) {
      if (profile.kind == 'self') {
        return profile;
      }
    }
    return null;
  });
});

/// Live medications of the self profile, by name.
final selfMedicationsProvider = StreamProvider<List<MedicationRow>>((
  ref,
) async* {
  final profile = await ref.watch(selfProfileProvider.future);
  if (profile == null) {
    yield const <MedicationRow>[];
    return;
  }
  yield* ref.watch(medicationsRepositoryProvider).watchForProfile(profile.id);
});

/// All live schedules with parsed rules.
final parsedSchedulesProvider = StreamProvider<List<ParsedSchedule>>((ref) {
  return ref.watch(schedulesRepositoryProvider).watchAll().map(parseSchedules);
});

/// A half-open instant window `[from, to)`.
typedef InstantWindow = ({DateTime from, DateTime to});

/// Dose events of all medications in a window, oldest first.
final doseEventsProvider =
    StreamProvider.family<List<DoseEventRow>, InstantWindow>((ref, window) {
  return ref
      .watch(doseEventsRepositoryProvider)
      .watchBetween(window.from, window.to);
});

/// Combines three async values; loading or error if any of them is.
AsyncValue<R> combine3<A, B, C, R>(
  AsyncValue<A> a,
  AsyncValue<B> b,
  AsyncValue<C> c,
  R Function(A a, B b, C c) build,
) {
  for (final value in <AsyncValue<Object?>>[a, b, c]) {
    if (value.hasError) {
      return AsyncError<R>(value.error!, value.stackTrace ?? StackTrace.empty);
    }
  }
  if (a.hasValue && b.hasValue && c.hasValue) {
    return AsyncData(build(a.requireValue, b.requireValue, c.requireValue));
  }
  return const AsyncLoading();
}

/// Records dose events for the screens; every write triggers a sync.
final doseActionsProvider = Provider<DoseActions>(DoseActions.new);

/// Marking doses (TZ §2.4): taken, skipped, snoozed, undo.
class DoseActions {
  /// Creates the actions.
  DoseActions(this._ref);

  final Ref<Object?> _ref;

  DoseEventsRepository get _events => _ref.read(doseEventsRepositoryProvider);

  // Event instants use the server-corrected clock: the server bounds `at`
  // by its own time.
  DateTime _now() => _ref.read(serverClockProvider).now();

  /// Marks a scheduled dose as taken.
  Future<void> take(ScheduledDose dose) => _record(dose, DoseEventType.taken);

  /// Marks a scheduled dose as skipped.
  Future<void> skip(ScheduledDose dose) => _record(dose, DoseEventType.skipped);

  /// Postpones a scheduled dose (the reminder itself is rescheduled in 2.3).
  Future<void> snooze(ScheduledDose dose) =>
      _record(dose, DoseEventType.snoozed);

  /// Cancels an earlier event.
  Future<void> undo(String eventId) async {
    await _events.undo(targetEventId: eventId, at: _now());
    requestSyncFrom(_ref);
  }

  /// Records an as-needed intake (no occurrence).
  Future<void> takeAsNeeded(String medicationId) async {
    await _events.record(
      medicationId: medicationId,
      type: DoseEventType.taken,
      at: _now(),
    );
    requestSyncFrom(_ref);
  }

  Future<void> _record(ScheduledDose dose, DoseEventType type) async {
    await _events.record(
      medicationId: dose.medication.id,
      type: type,
      at: _now(),
      occurrence: dose.ref,
    );
    requestSyncFrom(_ref);
  }
}

/// Unawaited call of a dose action from a widget callback.
void runDoseAction(Future<void> action) => unawaited(action);
