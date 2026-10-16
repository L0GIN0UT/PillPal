import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../data/repositories/dose_events_repository.dart';

/// Length of `YYYY-MM-DDTHH:MM` at the end of an occurrence key.
const int _keySuffixLength = 16;
const int _keyDateLength = 10;
final RegExp _timePattern = RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$');

/// The payload of a reminder notification (ADR 0001 §8): the occurrence key
/// and the medication id only, as compact JSON `{"k": ..., "m": ...}`.
@immutable
class ReminderPayload {
  /// Creates a payload.
  const ReminderPayload({
    required this.occurrenceKey,
    required this.medicationId,
  });

  /// Parses [raw]; null when it is not a reminder payload.
  static ReminderPayload? tryDecode(String? raw) {
    if (raw == null) {
      return null;
    }
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, Object?>) {
        final key = json['k'];
        final medication = json['m'];
        if (key is String && medication is String && medication.isNotEmpty) {
          return occurrenceRefOf(key) == null
              ? null
              : ReminderPayload(occurrenceKey: key, medicationId: medication);
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// `{scheduleId}/{YYYY-MM-DD}T{HH:MM}`.
  final String occurrenceKey;

  /// Opaque medication id.
  final String medicationId;

  /// Compact JSON form.
  String encode() => jsonEncode({'k': occurrenceKey, 'm': medicationId});

  /// The occurrence as a repository reference.
  OccurrenceRef? get occurrence => occurrenceRefOf(occurrenceKey);

  @override
  bool operator ==(Object other) =>
      other is ReminderPayload &&
      other.occurrenceKey == occurrenceKey &&
      other.medicationId == medicationId;

  @override
  int get hashCode => Object.hash(occurrenceKey, medicationId);
}

/// Parses an occurrence key; null unless it is in canonical form.
OccurrenceRef? occurrenceRefOf(String key) {
  final separator = key.length - _keySuffixLength - 1;
  if (separator < 1 || key[separator] != '/') {
    return null;
  }
  final suffix = key.substring(separator + 1);
  final date = LocalDate.tryParse(suffix.substring(0, _keyDateLength));
  final time = suffix.substring(_keyDateLength + 1);
  if (date == null ||
      suffix[_keyDateLength] != 'T' ||
      !_timePattern.hasMatch(time)) {
    return null;
  }
  final ref = OccurrenceRef(
    scheduleId: key.substring(0, separator),
    localDate: date,
    localTime: time,
  );
  return ref.key == key ? ref : null;
}

/// Opaque thread / group id of an occurrence's notifications: a hash, not
/// the key itself, which encodes dose times (ADR 0001 §7).
String occurrenceThreadId(String occurrenceKey) =>
    fnv1a32(occurrenceKey).toRadixString(16).padLeft(8, '0');
