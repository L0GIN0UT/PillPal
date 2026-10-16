import 'package:flutter/foundation.dart';

import '../data/clock.dart';
import '../data/db/database.dart';
import '../data/db/sync_state_store.dart';
import '../data/repositories/dose_events_repository.dart';
import '../data/repositories/local_writer.dart';
import 'notification_scheduler.dart';
import 'reminder_inputs.dart';
import 'reminder_payload.dart';
import 'reminder_settings.dart';

/// What the user chose on a notification.
enum ReminderActionKind {
  /// "Taken".
  taken,

  /// "Snooze 15 min".
  snooze,

  /// "Skip".
  skip,
}

/// A notification action with the occurrence it belongs to.
@immutable
class ReminderAction {
  /// Creates an action.
  const ReminderAction(this.kind, this.payload);

  /// The action of a notification response; null for a plain tap, an
  /// unknown action or a payload that is not a reminder's.
  static ReminderAction? fromResponse({
    required String? actionId,
    required String? payload,
  }) {
    final kind = switch (actionId) {
      ReminderActionIds.taken => ReminderActionKind.taken,
      ReminderActionIds.snooze => ReminderActionKind.snooze,
      ReminderActionIds.skip => ReminderActionKind.skip,
      _ => null,
    };
    final decoded = ReminderPayload.tryDecode(payload);
    return kind == null || decoded == null
        ? null
        : ReminderAction(kind, decoded);
  }

  /// The chosen action.
  final ReminderActionKind kind;

  /// The notification's occurrence and medication.
  final ReminderPayload payload;
}

/// How an action was handled.
enum ReminderActionOutcome {
  /// A dose event was appended (and queued for sync).
  recorded,

  /// The occurrence was already taken or skipped; nothing was recorded.
  alreadyHandled,

  /// The medication or occurrence is not known locally.
  rejected,
}

/// Turns a notification action into a dose event (ADR 0001 §7). Local
/// writes only: no network, no tokens - sync runs in the main isolate.
class ReminderActionHandler {
  /// Creates a handler.
  ReminderActionHandler({
    required AppDatabase db,
    required Clock clock,
    required IdGenerator newId,
  })  : _db = db,
        _clock = clock,
        _newId = newId;

  final AppDatabase _db;
  final Clock _clock;
  final IdGenerator _newId;

  /// Records [action]. Each call uses a new random UUIDv4 as the event id;
  /// a retry of the same push reuses the stored outbox entry, so the event
  /// is still recorded once. `taken` / `skip` / `snooze` on an occurrence
  /// that is already handled is ignored (a second tap on another
  /// notification of the same occurrence).
  Future<ReminderActionOutcome> handle(ReminderAction action) async {
    final occurrence = action.payload.occurrence;
    if (occurrence == null) {
      return ReminderActionOutcome.rejected;
    }
    final now = _clock().toUtc();
    final states = await ReminderInputsLoader(_db)
        .statesSince(now.subtract(doseEventLookback));
    if (states.handled.contains(action.payload.occurrenceKey)) {
      return ReminderActionOutcome.alreadyHandled;
    }
    final events = DoseEventsRepository(
      LocalWriter(
        db: _db,
        syncState: SyncStateStore(_db, _newId),
        clock: _clock,
        newId: _newId,
      ),
    );
    final medicationId = action.payload.medicationId;
    final id = _newId();
    try {
      switch (action.kind) {
        case ReminderActionKind.taken:
        case ReminderActionKind.skip:
          await events.record(
            id: id,
            medicationId: medicationId,
            type: action.kind == ReminderActionKind.taken
                ? DoseEventType.taken
                : DoseEventType.skipped,
            at: now,
            occurrence: occurrence,
          );
        case ReminderActionKind.snooze:
          await events.snooze(
            id: id,
            medicationId: medicationId,
            occurrence: occurrence,
            at: now,
            until: now.add(notificationSnooze),
          );
      }
    } on DataException {
      return ReminderActionOutcome.rejected;
    }
    return ReminderActionOutcome.recorded;
  }
}
