import 'dart:ui';

import 'package:pillpal_core/pillpal_core.dart';

import '../../l10n/gen/app_localizations.dart';
import 'reminder_inputs.dart';
import 'reminder_settings.dart';

/// Length of `HH:MM` at the end of an occurrence key.
const int _keyTimeLength = 5;

/// Visible text of one notification.
class ReminderContent {
  /// Creates content.
  const ReminderContent({required this.title, required this.body});

  /// Notification title.
  final String title;

  /// Notification body.
  final String body;
}

/// The supported locale closest to [preferred] (English otherwise). Works
/// without a `BuildContext`, so the background isolate renders the same
/// text as the app.
Locale reminderLocale(Locale? preferred) {
  final language = preferred?.languageCode;
  for (final supported in AppLocalizations.supportedLocales) {
    if (supported.languageCode == language) {
      return supported;
    }
  }
  return const Locale('en');
}

/// Localized strings for [locale] without a `BuildContext`.
AppLocalizations reminderStrings(Locale locale) =>
    lookupAppLocalizations(reminderLocale(locale));

/// The text of [request] for [target], following the medication's privacy
/// (TZ §2.5, `.claude/rules/privacy.md`) and the device setting
/// [hideMedicationNames]: see [showsMedicationDetails]; every other
/// reminder shows a generic text.
ReminderContent reminderContent(
  AppLocalizations strings,
  ReminderTarget target,
  NotificationRequest request, {
  required bool hideMedicationNames,
}) {
  final shared = showsMedicationDetails(
    target.privacy,
    hideMedicationNames: hideMedicationNames,
  );
  final title = shared
      ? strings.reminderTitleShared(target.medicationName)
      : strings.reminderTitleGeneric;
  final details = shared
      ? _doseText(strings, target.rule, request.occurrenceKey)
      : strings.reminderBodyGeneric;
  final String body;
  if (request.isSnooze) {
    body = strings.reminderBodySnoozed(details);
  } else if (request.repeatIndex > 0) {
    body = strings.reminderBodyRepeat(details);
  } else {
    body = details;
  }
  return ReminderContent(title: title, body: body);
}

String _doseText(
  AppLocalizations strings,
  ScheduleRule rule,
  String occurrenceKey,
) {
  final time = occurrenceKey.length > _keyTimeLength
      ? occurrenceKey.substring(occurrenceKey.length - _keyTimeLength)
      : '';
  for (final slot in rule.times) {
    if (slot.time == time) {
      final dose = slot.dose;
      return dose.unit == DoseUnit.other
          ? strings.reminderBodyAmount(dose.amount)
          : strings.reminderBodyDose(
              dose.amount,
              strings.reminderDoseUnit(dose.unit.name),
            );
    }
  }
  return strings.reminderBodyGeneric;
}
