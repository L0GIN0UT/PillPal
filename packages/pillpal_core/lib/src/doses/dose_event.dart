/// Dose event kinds (TZ §2.4, `docs/spec/dose-state.md` §1.2).
enum DoseEventType {
  /// The dose was taken.
  taken('taken'),

  /// The dose was deliberately skipped.
  skipped('skipped'),

  /// The reminder was postponed (`snoozeUntil`).
  snoozed('snoozed'),

  /// Cancels an earlier event (`targetEventId`).
  undo('undo');

  const DoseEventType(this.wire);

  /// Wire name, the `type` of the API and of the local database.
  final String wire;

  /// The type named [wire], or null for an unknown name.
  static DoseEventType? fromWire(String wire) {
    for (final type in values) {
      if (type.wire == wire) {
        return type;
      }
    }
    return null;
  }
}

/// One dose event as the dose-state fold sees it.
///
/// Instants are compared as moments, whatever their zone flag.
class DoseEvent {
  /// Creates an event.
  const DoseEvent({
    required this.id,
    required this.type,
    required this.at,
    this.occurrenceKey,
    this.targetEventId,
    this.snoozeUntil,
  });

  /// Unique id, compared as a string (ties of equal [at]).
  final String id;

  /// What happened.
  final DoseEventType type;

  /// When it happened (client clock).
  final DateTime at;

  /// The occurrence it refers to (`{scheduleId}/{YYYY-MM-DD}T{HH:MM}`).
  final String? occurrenceKey;

  /// For [DoseEventType.undo]: the event it cancels.
  final String? targetEventId;

  /// For [DoseEventType.snoozed]: when the dose is due again.
  final DateTime? snoozeUntil;

  @override
  bool operator ==(Object other) =>
      other is DoseEvent &&
      other.id == id &&
      other.type == type &&
      other.at == at &&
      other.occurrenceKey == occurrenceKey &&
      other.targetEventId == targetEventId &&
      other.snoozeUntil == snoozeUntil;

  @override
  int get hashCode =>
      Object.hash(id, type, at, occurrenceKey, targetEventId, snoozeUntil);
}
