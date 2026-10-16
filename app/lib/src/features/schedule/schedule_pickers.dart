import 'package:flutter/material.dart';
import 'package:pillpal_core/pillpal_core.dart';

/// Shows a 24-hour time picker at [time] (`HH:MM`); the picked `HH:MM`, or
/// null when cancelled.
Future<String?> pickSlotTime(BuildContext context, String time) async {
  final picked = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(
      hour: int.parse(time.substring(0, 2)),
      minute: int.parse(time.substring(3)),
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: child ?? const SizedBox.shrink(),
    ),
  );
  if (picked == null) {
    return null;
  }
  return '${picked.hour.toString().padLeft(2, '0')}:'
      '${picked.minute.toString().padLeft(2, '0')}';
}

/// Shows a date picker at [current]; the picked date, or null.
Future<LocalDate?> pickLocalDate(
  BuildContext context,
  LocalDate current,
) async {
  final picked = await showDatePicker(
    context: context,
    initialDate: DateTime(current.year, current.month, current.day),
    firstDate: DateTime(2000),
    lastDate: DateTime(2199, 12, 31),
  );
  return picked == null
      ? null
      : LocalDate(picked.year, picked.month, picked.day);
}
