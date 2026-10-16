import 'package:flutter/foundation.dart';

import '../../data/db/database.dart';
import '../../data/repositories/medications_repository.dart';
import '../common/local_time.dart';

/// Per-medication privacy (TZ §2.1), enforced server-side for relatives.
enum MedicationPrivacy {
  /// Relatives see the medication ("Близким").
  shared('shared'),

  /// Relatives see time and status only ("Без названия").
  anonymous('anonymous'),

  /// Only the owner ("Только мне").
  hidden('hidden');

  const MedicationPrivacy(this.wire);

  /// Wire value.
  final String wire;

  /// The value for [wire], defaulting to [shared].
  static MedicationPrivacy of(String wire) => MedicationPrivacy.values
      .firstWhere((value) => value.wire == wire, orElse: () => shared);
}

/// Field limits of `MedicationFields` (backend/app/validators.py).
abstract final class MedicationLimits {
  /// Name length.
  static const int name = 200;

  /// Form and strength length.
  static const int shortText = 100;

  /// Notes length.
  static const int notes = 2000;

  /// Stock unit length.
  static const int stockUnit = 32;

  /// Low-stock threshold, days.
  static const int maxLowStockDays = 365;
}

/// Validated fields of the medication form.
enum MedicationField {
  /// Name.
  medicationName,

  /// Dosage form.
  form,

  /// Strength.
  strength,

  /// Notes.
  notes,

  /// Fixed time zone.
  zone,

  /// Stock amount.
  stockCount,

  /// Stock unit.
  stockUnit,

  /// Low-stock threshold.
  lowStockDays;

  /// The form field of a `DataException.field` wire name, if any.
  static MedicationField? ofWire(String? field) {
    switch (field) {
      case 'name':
        return medicationName;
      case 'form':
        return form;
      case 'strength_text':
        return strength;
      case 'notes':
        return notes;
      case 'tz_mode':
      case 'fixed_tz':
        return zone;
      case 'stock_count':
        return stockCount;
      case 'stock_unit':
        return stockUnit;
      case 'low_stock_days':
        return lowStockDays;
      default:
        return null;
    }
  }
}

/// Validation error codes of the medication form.
abstract final class MedicationFormErrors {
  /// Empty required field.
  static const String required = 'required';

  /// Unknown IANA zone.
  static const String invalidZone = 'invalid_zone';

  /// Not a non-negative decimal with up to 3 fraction digits.
  static const String invalidNumber = 'invalid_number';

  /// Rejected by the data layer's server-rule check.
  static const String invalid = 'invalid';
}

final RegExp _stockPattern = RegExp(r'^(0|[1-9][0-9]{0,8})([.,][0-9]{1,3})?$');

/// The raw medication form (text as typed).
@immutable
class MedicationFormInput {
  /// Creates an input.
  const MedicationFormInput({
    this.name = '',
    this.form = '',
    this.strength = '',
    this.notes = '',
    this.privacy = MedicationPrivacy.shared,
    this.fixedZone = false,
    this.zone = '',
    this.trackStock = false,
    this.stockCount = '',
    this.stockUnit = '',
    this.lowStockDays = '',
  });

  /// The form of an existing medication; [deviceTz] pre-fills the zone.
  factory MedicationFormInput.fromRow(MedicationRow row, String deviceTz) {
    return MedicationFormInput(
      name: row.name,
      form: row.form ?? '',
      strength: row.strengthText ?? '',
      notes: row.notes ?? '',
      privacy: MedicationPrivacy.of(row.privacy),
      fixedZone: row.tzMode == 'fixed',
      zone: row.fixedTz ?? deviceTz,
      trackStock: row.stockCount != null,
      stockCount: row.stockCount ?? '',
      stockUnit: row.stockUnit ?? '',
      lowStockDays: row.lowStockDays?.toString() ?? '',
    );
  }

  /// Name.
  final String name;

  /// Dosage form (free text).
  final String form;

  /// Strength (free text).
  final String strength;

  /// Notes.
  final String notes;

  /// Visibility to relatives.
  final MedicationPrivacy privacy;

  /// Whether times are pinned to [zone] (`tz_mode = fixed`).
  final bool fixedZone;

  /// IANA zone for [fixedZone].
  final String zone;

  /// Whether stock is tracked.
  final bool trackStock;

  /// Stock amount as typed ("54", "12,5").
  final String stockCount;

  /// Stock unit.
  final String stockUnit;

  /// Low-stock threshold as typed.
  final String lowStockDays;

  /// Field errors (codes from [MedicationFormErrors]); empty when valid.
  Map<MedicationField, String> validate() {
    final errors = <MedicationField, String>{};
    if (name.trim().isEmpty) {
      errors[MedicationField.medicationName] = MedicationFormErrors.required;
    }
    if (fixedZone && !isKnownTimeZone(zone.trim())) {
      errors[MedicationField.zone] = MedicationFormErrors.invalidZone;
    }
    if (trackStock) {
      if (!_stockPattern.hasMatch(stockCount.trim())) {
        errors[MedicationField.stockCount] = MedicationFormErrors.invalidNumber;
      }
      final days = lowStockDays.trim();
      final parsed = int.tryParse(days);
      if (days.isNotEmpty &&
          (parsed == null ||
              parsed < 0 ||
              parsed > MedicationLimits.maxLowStockDays)) {
        errors[MedicationField.lowStockDays] =
            MedicationFormErrors.invalidNumber;
      }
    }
    return errors;
  }

  /// The repository draft; call only when [validate] is empty.
  MedicationDraft toDraft() {
    String? optional(String value) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    return MedicationDraft(
      name: name.trim(),
      form: optional(form),
      strengthText: optional(strength),
      notes: optional(notes),
      tzMode: fixedZone ? 'fixed' : 'local',
      fixedTz: fixedZone ? zone.trim() : null,
      stockCount: trackStock ? stockCount.trim().replaceAll(',', '.') : null,
      stockUnit: trackStock ? optional(stockUnit) : null,
      lowStockDays: trackStock ? int.tryParse(lowStockDays.trim()) : null,
      privacy: privacy.wire,
    );
  }
}
