import 'dart:convert';

import '../api/json.dart';
import '../catalog/manual_ingredient.dart';
import '../db/database.dart';
import 'local_writer.dart';

// Full-state `data` of sync push upserts, one per entity (`ProfileData`,
// `MedicationData`, `ScheduleData`, `DoseEventData` in spec/openapi.json).

/// `ProfileData`.
JsonMap profilePayload(ProfileRow row) => {
      'kind': row.kind,
      'display_name': row.displayName,
      'timezone': row.timezone,
      'missed_alert_minutes': row.missedAlertMinutes,
      'missed_alerts_enabled': row.missedAlertsEnabled,
    };

/// `MedicationData`. The catalog references are always sent with an
/// explicit value (an absent key would mean "keep" to the server).
///
/// [fullAccess] (owner, co-guardian) adds `gtin_link_shared`; for other
/// roles the key is omitted, because an editor that sends it is refused
/// with `forbidden_field` (ADR 0015 §4). [consentVersion] is the write-only
/// `gtin_link_consent_version`: only the mutation of the user's tick passes
/// one, and only together with `gtin_link_shared: true`.
JsonMap medicationPayload(
  MedicationRow row, {
  required bool fullAccess,
  int? consentVersion,
}) {
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
    'stock_set_at':
        stockSetAt == null ? null : instantToJson(microsToInstant(stockSetAt)),
    'privacy': row.privacy,
    'catalog_product_id': row.catalogProductId,
    'catalog_package_id': row.catalogPackageId,
    'catalog_composition_id': row.catalogCompositionId,
    'gtin': row.gtin,
    'manual_ingredients': _manualIngredientsJson(row.manualIngredients),
    if (fullAccess) 'gtin_link_shared': row.gtinLinkShared,
    if (fullAccess && row.gtinLinkShared && consentVersion != null)
      'gtin_link_consent_version': consentVersion,
  };
}

List<Object?>? _manualIngredientsJson(String? stored) {
  if (stored == null) {
    return null;
  }
  return ManualIngredient.decode(stored).map((l) => l.toJson()).toList();
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
