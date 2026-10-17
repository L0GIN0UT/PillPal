import 'dart:convert';

import 'package:pillpal_core/pillpal_core.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';

/// The dose shown for every slot of a redacted schedule. A relative never
/// sees the doses of an `anonymous` medication (ADR 0006 §3) but the rule
/// model requires one, so the parser fills this in; nothing renders it.
const Map<String, Object?> redactedDose = {'amount': '1', 'unit': 'tablet'};

/// Fixed namespace of [splitScheduleId] (random, never changes).
const String _splitNamespace = '6f1c2d3e-8a4b-5c6d-9e7f-0a1b2c3d4e5f';

const Uuid _uuid = Uuid();

/// The id of the schedule that continues [scheduleId] after a split on
/// [splitDate] (the old schedule's last day): a UUID v5 of
/// `{schedule_id}/{split_date}`. Two devices that split the same schedule
/// on the same day create the same row, so their edits converge by
/// last-write-wins instead of leaving two live copies.
String splitScheduleId(String scheduleId, LocalDate splitDate) =>
    _uuid.v5(_splitNamespace, '$scheduleId/$splitDate');

/// The rule of [row]. A redacted row has no doses in its time slots: they
/// are replaced by [redactedDose].
///
/// Throws [RuleValidationError] or [FormatException] like
/// `ScheduleRule.fromJson` for a stored rule that is not valid.
ScheduleRule parseScheduleRow(ScheduleRow row) {
  final Object? json = jsonDecode(row.rule);
  return ScheduleRule.fromJson(
    row.redacted ? _withPlaceholderDoses(json) : json,
  );
}

Object? _withPlaceholderDoses(Object? rule) {
  if (rule is! Map<String, Object?>) {
    return rule; // fromJson rejects it
  }
  final times = rule['times'];
  if (times is! List<Object?>) {
    return rule;
  }
  return {
    ...rule,
    'times': [
      for (final slot in times)
        slot is Map<String, Object?> ? {...slot, 'dose': redactedDose} : slot,
    ],
  };
}
