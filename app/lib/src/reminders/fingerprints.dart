import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'reminder_settings.dart';

// Fingerprints of applied notifications (docs/spec/reminders.md §8). They
// cover only the fields that change a reminder - never row versions or
// conflict keys, which also change when a sync rewrites identical content
// (that would cancel and reschedule every notification after each pull).
// They are SHA-256 digests, so the stored value holds no medical text.

/// The schedule state a notification was planned from: rule, zone mode,
/// level and repeats, on/off and privacy. A change settles every applied
/// notification of the schedule, delivered ones included (a medication made
/// `hidden` leaves the tray).
String scheduleFingerprint({
  required ScheduleRule rule,
  required String tzMode,
  required String? fixedTz,
  required ReminderSettings settings,
  required String privacy,
}) =>
    _digest([
      'schedule/v1',
      rule.toJson(),
      tzMode,
      fixedTz,
      settings.level.name,
      settings.repeatEveryMinutes,
      settings.maxRepeats,
      settings.enabled,
      privacy,
    ]);

/// How a notification looks and is delivered: level (channel, interruption
/// level), exact or inexact alarm, privacy, locale and the rendered text
/// (medication name, dose, repeat or snooze variant). A change reschedules
/// the future notification under the same id.
String displayFingerprint({
  required ReminderLevel level,
  required bool exact,
  required String privacy,
  required String locale,
  required String title,
  required String body,
}) =>
    _digest(['display/v1', level.name, exact, privacy, locale, title, body]);

String _digest(List<Object?> fields) =>
    sha256.convert(utf8.encode(jsonEncode(fields))).toString();
