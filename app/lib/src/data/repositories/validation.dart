import 'package:pillpal_core/pillpal_core.dart';

import 'local_writer.dart';

// Client-side mirror of the server's field rules (backend/app/validators.py,
// backend/app/schemas/entities.py), so invalid input is refused at write time
// instead of being parked by the server after sync. Text is normalised the
// way the server stores it (trimmed where the server trims), and lengths
// count Unicode code points like Python's len().

final RegExp _controlChars = RegExp('[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]');
final RegExp _stockPattern = RegExp(r'^[0-9]{1,9}(\.[0-9]{1,3})?$');

/// Field limits.
abstract final class FieldLimits {
  /// `DisplayName`.
  static const int displayName = 100;

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

  /// `low_stock_days` upper bound.
  static const int lowStockDays = 365;
}

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
