import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../../data/repositories/dose_events_repository.dart';
import '../auth/auth_session.dart';
import '../common/local_time.dart';
import 'dose_status.dart';
import 'scheduled_doses.dart';

// UI-side reads over the data layer's repositories (drift streams), shared
// by Today, Medications and History.

/// The user's own profile (kind `self` in a scope the account owns; other
/// people's `self` profiles never qualify); null until the first pull
/// delivered it.
final selfProfileProvider = StreamProvider<ProfileRow?>((ref) {
  return ref.watch(accessRepositoryProvider).watchOwnSelfProfile();
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

/// Live schedules of the self profile's medications with parsed rules.
/// Relatives' schedules, which the database holds too from milestone 3.6,
/// belong to their own screens (3.8) and never reach Today, History or the
/// report of the user.
final parsedSchedulesProvider = StreamProvider<List<ParsedSchedule>>((
  ref,
) async* {
  final profile = await ref.watch(selfProfileProvider.future);
  if (profile == null) {
    yield const <ParsedSchedule>[];
    return;
  }
  yield* ref
      .watch(schedulesRepositoryProvider)
      .watchForProfile(profile.id)
      .map(parseSchedules);
});

/// The days a screen shows: local dates `[first, last]` in the device zone
/// and their instants `[from, to)`.
typedef DayWindow = ({
  LocalDate first,
  LocalDate last,
  DateTime from,
  DateTime to,
});

/// The window of the device-local days `[first, last]` in [tz].
DayWindow dayWindow(LocalDate first, LocalDate last, String tz) => (
      first: first,
      last: last,
      from: dayBounds(first, tz).start,
      to: dayBounds(last, tz).end,
    );

/// Dose events the days of [DayWindow] need, oldest first (ADR 0003 §5):
/// scheduled events by occurrence key, whenever they were recorded, and
/// as-needed intakes by time.
///
/// Occurrence dates are nominal in the medication's zone, which may be a
/// day off the device date for fixed-zone medications, hence one day of
/// margin on both sides.
final doseEventsForDaysProvider = StreamProvider.autoDispose
    .family<List<DoseEventRow>, DayWindow>((ref, window) async* {
  final profile = await ref.watch(selfProfileProvider.future);
  final schedules = await ref.watch(parsedSchedulesProvider.future);
  final events = ref.watch(doseEventsRepositoryProvider).watchForDays(
    scheduleIds: [for (final schedule in schedules) schedule.row.id],
    firstDay: window.first.addDays(-1),
    lastDay: window.last.addDays(1),
    from: window.from,
    to: window.to,
  );
  // As-needed intakes are selected by time alone: keep the user's own.
  yield* events.map(
    (rows) => [
      for (final row in rows)
        if (row.profileId == profile?.id) row,
    ],
  );
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

/// Keys with a dose write in flight: occurrence keys, and
/// [asNeededWriteKey] for as-needed medications. Their buttons are disabled
/// meanwhile and repeated taps are ignored (ADR 0003 §6).
final doseWritesInFlightProvider =
    NotifierProvider<DoseWritesInFlight, Set<String>>(DoseWritesInFlight.new);

/// The set behind [doseWritesInFlightProvider].
class DoseWritesInFlight extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  /// Marks [key] busy; false when it already is.
  bool tryStart(String key) {
    if (state.contains(key)) {
      return false;
    }
    state = {...state, key};
    return true;
  }

  /// Marks [key] free again.
  void finish(String key) {
    state = {...state}..remove(key);
  }
}

/// The in-flight key of as-needed intakes of [medicationId].
String asNeededWriteKey(String medicationId) => 'as-needed/$medicationId';

/// Records dose events for the screens; every write triggers a sync.
final doseActionsProvider = Provider<DoseActions>(DoseActions.new);

/// Marking doses (TZ §2.4): taken, skipped, snoozed, undo.
///
/// Every write is guarded by its key in [doseWritesInFlightProvider], and
/// marks and undos are no-ops when already in effect (checked in the write
/// transaction), so a double tap records one event.
class DoseActions {
  /// Creates the actions.
  DoseActions(this._ref);

  final Ref<Object?> _ref;

  DoseEventsRepository get _events => _ref.read(doseEventsRepositoryProvider);

  // Event instants use the server-corrected clock: the server bounds `at`
  // by its own time.
  DateTime _now() => _ref.read(serverClockProvider).now();

  /// Marks a scheduled dose as taken; the new event's id, or null when
  /// nothing was recorded (already taken, or a write is running).
  Future<String?> take(ScheduledDose dose) => _mark(dose, DoseEventType.taken);

  /// Marks a scheduled dose as skipped; see [take].
  Future<String?> skip(ScheduledDose dose) =>
      _mark(dose, DoseEventType.skipped);

  /// Postpones a scheduled dose by [DoseTiming.snooze]; the reminder
  /// planner re-plans its notification from the `snooze_until` (2.3).
  Future<String?> snooze(ScheduledDose dose) {
    return _guarded(
      dose.occurrence.key,
      () {
        final now = _now();
        return _events.snooze(
          medicationId: dose.medication.id,
          occurrence: dose.ref,
          at: now,
          until: now.add(DoseTiming.snooze),
        );
      },
    );
  }

  /// Cancels the mark of [dose], if it has one.
  Future<String?> undo(ScheduledDose dose) async {
    final mark = dose.mark;
    if (mark == null) {
      return null;
    }
    return undoEvent(key: dose.occurrence.key, eventId: mark.eventId);
  }

  /// Cancels event [eventId], guarded by in-flight [key].
  Future<String?> undoEvent({required String key, required String eventId}) {
    return _guarded(
      key,
      () => _events.undoOnce(targetEventId: eventId, at: _now()),
    );
  }

  /// Records an as-needed intake (no occurrence).
  Future<String?> takeAsNeeded(String medicationId) {
    return _guarded(
      asNeededWriteKey(medicationId),
      () => _events.record(
        medicationId: medicationId,
        type: DoseEventType.taken,
        at: _now(),
      ),
    );
  }

  /// Cancels as-needed intake [eventId] of [medicationId].
  Future<String?> undoAsNeeded(String medicationId, String eventId) =>
      undoEvent(key: asNeededWriteKey(medicationId), eventId: eventId);

  Future<String?> _mark(ScheduledDose dose, DoseEventType type) {
    return _guarded(
      dose.occurrence.key,
      () => _events.recordMark(
        medicationId: dose.medication.id,
        type: type,
        at: _now(),
        occurrence: dose.ref,
        isApplied: (events) => effectiveMark(events)?.type == type,
      ),
    );
  }

  Future<String?> _guarded(
    String key,
    Future<String?> Function() write,
  ) async {
    final inFlight = _ref.read(doseWritesInFlightProvider.notifier);
    if (!inFlight.tryStart(key)) {
      return null;
    }
    try {
      final id = await write();
      if (id != null) {
        requestSyncFrom(_ref);
      }
      return id;
    } finally {
      inFlight.finish(key);
    }
  }
}
