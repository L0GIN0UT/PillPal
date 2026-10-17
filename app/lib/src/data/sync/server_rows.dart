import 'dart:convert';

import 'package:drift/drift.dart';

import '../api/json.dart';
import '../api/sync_dto.dart';
import '../db/database.dart';

// Server JSON (`*Out`, and the projected forms a relative receives, ADR 0006
// §3) to local rows. Keys read here are declared so that the contract test
// can check them against spec/openapi.json.

/// Keys read from `ProfileOut` (the projection keeps `kind`, `display_name`
/// and `timezone` only).
const Set<String> profileKeys = {
  'kind',
  'display_name',
  'timezone',
  'missed_alert_minutes',
  'missed_alerts_enabled',
};

/// Keys read from `MedicationOut`.
const Set<String> medicationKeys = {
  'profile_id',
  'name',
  'form',
  'strength_text',
  'notes',
  'tz_mode',
  'fixed_tz',
  'stock_count',
  'stock_unit',
  'low_stock_days',
  'stock_set_at',
  'privacy',
};

/// Keys read from `MedicationRedacted` (an `anonymous` medication as a
/// relative sees it).
const Set<String> redactedMedicationKeys = {
  'profile_id',
  'privacy',
  'tz_mode',
  'fixed_tz',
  'redacted',
};

/// Keys read from `ScheduleOut`.
const Set<String> scheduleKeys = {'medication_id', 'rule'};

/// Keys read from `ScheduleRedacted`.
const Set<String> redactedScheduleKeys = {'medication_id', 'rule', 'redacted'};

/// Keys read from `DoseEventOut`.
const Set<String> doseEventKeys = {
  'profile_id',
  'medication_id',
  'type',
  'at',
  'occurrence_key',
  'target_event_id',
  'note',
  'recorded_at',
  'device_id',
  'snooze_until',
};

final Set<String> _medicationReadKeys = {
  ...medicationKeys,
  ...redactedMedicationKeys,
};

final Set<String> _scheduleReadKeys = {
  ...scheduleKeys,
  ...redactedScheduleKeys,
};

/// Whether server [data] is a redacted (`anonymous`) medication or schedule.
bool isRedacted(JsonMap data) => data['redacted'] == true;

/// The conflict key of a live mutable entity's state.
class RowKey {
  /// Creates a key.
  const RowKey(this.micros, this.device);

  /// The key of [state]. [lenient] accepts the projected envelope of
  /// someone else's profile (no device, and no key at all for redacted
  /// rows): relatives never write those, so the key only has to exist.
  factory RowKey.of(EntityState state, {bool lenient = false}) {
    final at = state.clientUpdatedAt;
    final device = state.updatedByDevice;
    if (lenient) {
      return RowKey(at?.microsecondsSinceEpoch ?? 0, device ?? '');
    }
    if (at == null || device == null) {
      throw const FormatException('Mutable entity state without its key');
    }
    return RowKey(at.microsecondsSinceEpoch, device);
  }

  /// Microseconds since epoch (UTC).
  final int micros;

  /// Tie-break device id.
  final String device;
}

/// The profile companion for [data]. Alert settings the server did not send
/// (the projection omits them) are left alone on update.
ProfilesCompanion profileCompanion(String id, JsonMap data, RowKey key) {
  final reader = JsonReader(data, profileKeys);
  final minutes = reader.integerOrNull('missed_alert_minutes');
  final enabled = reader.booleanOrNull('missed_alerts_enabled');
  return ProfilesCompanion(
    id: Value(id),
    kind: Value(reader.string('kind')),
    displayName: Value(reader.string('display_name')),
    timezone: Value(reader.string('timezone')),
    clientUpdatedAt: Value(key.micros),
    updatedByDevice: Value(key.device),
    deletedAt: const Value(null),
    missedAlertMinutes: _valueOrAbsent(minutes),
    missedAlertsEnabled: _valueOrAbsent(enabled),
  );
}

Value<T> _valueOrAbsent<T>(T? value) =>
    value == null ? Value<T>.absent() : Value<T>(value);

/// The medication row for [data], redacted or full.
MedicationRow medicationRow(String id, JsonMap data, RowKey key) {
  final reader = JsonReader(data, _medicationReadKeys);
  final redacted = isRedacted(data);
  return MedicationRow(
    id: id,
    profileId: reader.string('profile_id'),
    name: redacted ? null : reader.string('name'),
    form: reader.stringOrNull('form'),
    strengthText: reader.stringOrNull('strength_text'),
    notes: reader.stringOrNull('notes'),
    tzMode: reader.string('tz_mode'),
    fixedTz: reader.stringOrNull('fixed_tz'),
    stockCount: reader.stringOrNull('stock_count'),
    stockUnit: reader.stringOrNull('stock_unit'),
    lowStockDays: reader.integerOrNull('low_stock_days'),
    stockSetAt: reader.instantOrNull('stock_set_at')?.microsecondsSinceEpoch,
    privacy: reader.string('privacy'),
    redacted: redacted,
    clientUpdatedAt: key.micros,
    updatedByDevice: key.device,
  );
}

/// The schedule row for [data], redacted (a rule without doses) or full.
ScheduleRow scheduleRow(String id, JsonMap data, RowKey key) {
  final reader = JsonReader(data, _scheduleReadKeys);
  return ScheduleRow(
    id: id,
    medicationId: reader.string('medication_id'),
    rule: jsonEncode(reader.object('rule')),
    redacted: isRedacted(data),
    clientUpdatedAt: key.micros,
    updatedByDevice: key.device,
  );
}

/// The dose event row for [data].
DoseEventRow doseEventRow(String id, JsonMap data) {
  final reader = JsonReader(data, doseEventKeys);
  return DoseEventRow(
    id: id,
    profileId: reader.string('profile_id'),
    medicationId: reader.string('medication_id'),
    eventType: reader.string('type'),
    at: reader.instant('at').microsecondsSinceEpoch,
    occurrenceKey: reader.stringOrNull('occurrence_key'),
    targetEventId: reader.stringOrNull('target_event_id'),
    note: reader.stringOrNull('note'),
    recordedAt: reader.instantOrNull('recorded_at')?.microsecondsSinceEpoch,
    deviceId: reader.stringOrNull('device_id'),
    snoozeUntil: reader.instantOrNull('snooze_until')?.microsecondsSinceEpoch,
  );
}
