import 'package:pillpal_core/pillpal_core.dart';

import 'local_writer.dart';

// Client-side mirror of the server's field rules (backend/app/validators.py,
// backend/app/schemas/entities.py), so invalid input is refused at write time
// instead of being parked by the server after sync. Text is normalised the
// way the server stores it (trimmed where the server trims), and lengths
// count Unicode code points like Python's len().

final RegExp _controlChars = RegExp('[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]');
// A short text other people read (a person's own name) refuses C0/C1
// controls (tab and line breaks too), invisible format characters, bidi
// marks and overrides, line separators and the Hangul fillers that render as
// blanks: `single_line_text` in backend/app/validators.py.
final RegExp _hiddenChars = RegExp(
  '[\x00-\x1f\x7f-\x9f\u00ad\u061c\u115f\u1160\u180e\u200b-\u200f'
  '\u2028-\u202e\u2060-\u2064\u2066-\u2069\u3164\ufeff\uffa0]',
);

// A letter or digit in any script (`has_letter_or_digit`, Python's
// `str.isalnum`).
final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

final RegExp _stockPattern = RegExp(r'^[0-9]{1,9}(\.[0-9]{1,3})?$');

/// The server's default for `missed_alert_minutes` (`ProfileOut`).
const int defaultMissedAlertMinutes = 30;

/// Field limits.
abstract final class FieldLimits {
  /// `DisplayName`.
  static const int displayName = 100;

  /// `PersonName` lower bound: a person's own name (the `self` profile).
  static const int personNameMin = 2;

  /// `PersonName` upper bound.
  static const int personNameMax = 20;

  /// `Name200`.
  static const int medicationName = 200;

  /// `ShortText` (form, strength).
  static const int shortText = 100;

  /// `UnitText`.
  static const int unit = 32;

  /// `Notes`.
  static const int notes = 2000;

  /// `EventNote`.
  static const int eventNote = 1000;

  /// IANA zone name.
  static const int timezone = 64;

  /// `missed_alert_minutes` lower bound (`ProfileData`).
  static const int missedAlertMinutesMin = 5;

  /// `missed_alert_minutes` upper bound (`ProfileData`).
  static const int missedAlertMinutesMax = 720;

  /// `low_stock_days` upper bound.
  static const int lowStockDays = 365;

  /// `manual_ingredients` items (`MedicationData`).
  static const int manualIngredients = 10;

  /// `ManualIngredient.name`.
  static const int ingredientName = 100;

  /// `ManualIngredient.strength_text`.
  static const int ingredientStrength = 50;

  /// `gtin_link_consent_version` upper bound (`MedicationData`).
  static const int consentVersionMax = 10000;
}

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{12}$',
);
final RegExp _gtin14Pattern = RegExp(r'^[0-9]{14}$');

DataException _invalid(String field) =>
    DataException(DataException.validationError, field: field);

void _checkText(String value, String field, int min, int max) {
  final length = value.runes.length;
  if (length < min || length > max || _controlChars.hasMatch(value)) {
    throw _invalid(field);
  }
}

/// A required text: trimmed (if [trim]), [min]..[max] code points, no
/// control characters.
String requiredText(
  String value,
  String field, {
  required int max,
  int min = 1,
  bool trim = true,
}) {
  final normalised = trim ? value.trim() : value;
  _checkText(normalised, field, min, max);
  return normalised;
}

/// Whether [value], trimmed, is a person's own name (`PersonName`): what
/// relatives see, [FieldLimits.personNameMin]..[FieldLimits.personNameMax]
/// code points, only visible characters on one line, with a letter or digit.
bool isPersonName(String value) {
  final name = value.trim();
  final length = name.runes.length;
  return length >= FieldLimits.personNameMin &&
      length <= FieldLimits.personNameMax &&
      !_hiddenChars.hasMatch(name) &&
      _letterOrDigit.hasMatch(name);
}

/// [value] trimmed when it is a person's own name ([isPersonName]).
String personName(String value, String field) {
  if (!isPersonName(value)) {
    throw _invalid(field);
  }
  return value.trim();
}

/// An optional text; empty (after trimming) becomes null.
String? optionalText(
  String? value,
  String field, {
  required int max,
  bool trim = true,
}) {
  if (value == null) {
    return null;
  }
  final normalised = trim ? value.trim() : value;
  if (normalised.isEmpty) {
    return null;
  }
  _checkText(normalised, field, 1, max);
  return normalised;
}

/// A known IANA time zone.
String timezoneName(String value, String field) {
  if (value.isEmpty || value.length > FieldLimits.timezone) {
    throw _invalid(field);
  }
  try {
    localToUtc(LocalDate(2026, 1, 1), 0, 0, value);
  } on ArgumentError {
    throw _invalid(field);
  }
  return value;
}

/// One of [allowed].
String oneOf(String value, String field, Set<String> allowed) {
  if (!allowed.contains(value)) {
    throw _invalid(field);
  }
  return value;
}

/// An optional decimal stock: 0..999999999.999 with at most 3 decimals.
String? validStockCount(String? value, String field) {
  if (value == null) {
    return null;
  }
  final normalised = value.trim();
  if (!_stockPattern.hasMatch(normalised)) {
    throw _invalid(field);
  }
  return normalised;
}

/// An optional integer in [min]..[max].
int? optionalRange(int? value, String field, int min, int max) {
  if (value != null && (value < min || value > max)) {
    throw _invalid(field);
  }
  return value;
}

/// An instant the server accepts: at most `maxFutureSkew` after [now].
DateTime notFarFuture(
  DateTime value,
  DateTime now,
  Duration maxSkew,
  String field,
) {
  if (value.isAfter(now.add(maxSkew))) {
    throw _invalid(field);
  }
  return value.toUtc();
}

/// An optional UUID (a catalog id), lowercased as the server renders it.
String? optionalUuid(String? value, String field) {
  if (value == null) {
    return null;
  }
  if (!_uuidPattern.hasMatch(value)) {
    throw _invalid(field);
  }
  return value.toLowerCase();
}

/// An optional GTIN-14 (14 digits; a restricted number is allowed, the
/// server decides what is shareable).
String? optionalGtin14(String? value, String field) {
  if (value == null) {
    return null;
  }
  if (!_gtin14Pattern.hasMatch(value)) {
    throw _invalid(field);
  }
  return value;
}
