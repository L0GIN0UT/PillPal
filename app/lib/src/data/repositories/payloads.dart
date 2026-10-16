import 'dart:convert';

import '../api/json.dart';
import '../db/database.dart';
import 'local_writer.dart';

// Full-state `data` of sync push upserts, one per entity (`ProfileData`,
// `MedicationData`, `ScheduleData`, `DoseEventData` in spec/openapi.json).

/// `ProfileData`.
JsonMap profilePayload(ProfileRow row) => {
      'kind': row.kind,
      'display_name': row.displayName,
      'timezone': row.timezone,
    };

/// `MedicationData`.
JsonMap medicationPayload(MedicationRow row) {
  final stockSetAt = row.stockSetAt;
  return {
      'profile_id': row.profileId,
      'name': row.name,
      'form': row.form,
      'strength_text': row.strengthText,
      'notes': row.notes,
      'tz_mode': row.tzMode,
      'fixed_tz': row.fixedTz,
      'stock_count': row.stockCount,
      'stock_unit': row.stockUnit,
      'low_stock_days': row.lowStockDays,
      'stock_set_at': stockSetAt == null
          ? null
          : instantToJson(microsToInstant(stockSetAt)),
      'privacy': row.privacy,
    };
}

/// `ScheduleData`.
JsonMap schedulePayload(ScheduleRow row) => {
      'medication_id': row.medicationId,
      'rule': asJsonMap(jsonDecode(row.rule), 'rule'),
    };

/// `DoseEventData`. `snooze_until` is sent only for `snoozed` events.
JsonMap doseEventPayload(DoseEventRow row) {
  final snoozeUntil = row.snoozeUntil;
  return {
    'medication_id': row.medicationId,
    'type': row.eventType,
    'at': instantToJson(microsToInstant(row.at)),
    'occurrence_key': row.occurrenceKey,
    'target_event_id': row.targetEventId,
    'note': row.note,
    if (snoozeUntil != null)
      'snooze_until': instantToJson(microsToInstant(snoozeUntil)),
  };
}
