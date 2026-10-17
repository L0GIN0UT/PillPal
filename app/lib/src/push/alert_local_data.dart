import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../data/db/database.dart';
import '../reminders/reminder_settings_repository.dart';

/// A medication as the device knows it, projected for the account's role.
@immutable
class AlertMedication {
  /// Creates a medication.
  const AlertMedication({
    required this.name,
    required this.privacy,
    required this.redacted,
  });

  /// The name; null for a redacted (`anonymous`) medication.
  final String? name;

  /// `shared`, `anonymous` or `hidden`.
  final String privacy;

  /// Whether the server projected the medication (no name, ADR 0006 §3).
  final bool redacted;
}

/// The local facts an alert notification may use (ADR 0008 §2): a push only
/// carries ids, so the text comes from data the device already holds, already
/// projected by the server for this account's role (ADR 0006). Nothing here
/// touches the network.
abstract interface class AlertLocalData {
  /// Display name of [profileId], or null when the profile is not known.
  Future<String?> profileName(String profileId);

  /// [medicationId] of [profileId] as stored, or null when not known.
  Future<AlertMedication?> medication(String profileId, String medicationId);

  /// The device setting "hide medication names" (reminders use it too).
  Future<bool> hideMedicationNames();

  /// When the owner's devices last synced, floored to the hour by the server
  /// (`ScopeOut.owner_last_seen_at`); null when unknown.
  Future<DateTime?> ownerLastSeenAt(String profileId);

  /// The other person's display name on grant [grantId], or null.
  Future<String?> relativeName(String grantId);
}

/// [AlertLocalData] over the local drift database.
class DriftAlertLocalData implements AlertLocalData {
  /// Creates the reader.
  DriftAlertLocalData(this._db);

  final AppDatabase _db;

  @override
  Future<String?> profileName(String profileId) async {
    final row = await (_db.select(_db.profiles)
          ..where(
            (row) => row.id.equals(profileId) & row.deletedAt.isNull(),
          ))
        .getSingleOrNull();
    return _nonBlank(row?.displayName);
  }

  @override
  Future<AlertMedication?> medication(
    String profileId,
    String medicationId,
  ) async {
    final row = await (_db.select(_db.medications)
          ..where(
            (row) =>
                row.id.equals(medicationId) &
                row.profileId.equals(profileId) &
                row.deletedAt.isNull(),
          ))
        .getSingleOrNull();
    if (row == null) {
      return null;
    }
    return AlertMedication(
      name: _nonBlank(row.name),
      privacy: row.privacy,
      redacted: row.redacted,
    );
  }

  @override
  Future<bool> hideMedicationNames() =>
      ReminderSettingsRepository(_db).hideMedicationNames();

  @override
  Future<DateTime?> ownerLastSeenAt(String profileId) async {
    final row = await (_db.select(_db.accessScopes)
          ..where((row) => row.profileId.equals(profileId)))
        .getSingleOrNull();
    final micros = row?.ownerLastSeenAt;
    return micros == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
  }

  @override
  Future<String?> relativeName(String grantId) async {
    final row = await (_db.select(_db.relativeLinks)
          ..where((row) => row.id.equals(grantId)))
        .getSingleOrNull();
    return _nonBlank(row?.counterpartName);
  }

  static String? _nonBlank(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
