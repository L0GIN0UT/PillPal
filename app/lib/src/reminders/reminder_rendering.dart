import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../l10n/gen/app_localizations.dart';
import 'fingerprints.dart';
import 'notification_scheduler.dart';
import 'reminder_content.dart';
import 'reminder_inputs.dart';
import 'reminder_payload.dart';

/// An applied notification with the reminder handed to the platform.
@immutable
class RenderedReminder {
  /// Pairs [applied] with [reminder].
  const RenderedReminder(this.applied, this.reminder);

  /// What is stored once it is scheduled.
  final AppliedNotification applied;

  /// What the platform receives.
  final ScheduledReminder reminder;
}

/// Renders every request of [plan] in [locale]: visible text (privacy and
/// the name-hiding setting, ADR 0001 §8), opaque payload and thread id,
/// and both fingerprints (docs/spec/reminders.md §8).
List<RenderedReminder> renderPlan(
  ReminderPlan plan,
  ReminderInputs inputs, {
  required Locale locale,
  required bool exact,
}) {
  final strings = lookupAppLocalizations(locale);
  final actions = ReminderActionTitles(
    taken: strings.reminderActionTaken,
    snooze: strings.reminderActionSnooze,
    skip: strings.reminderActionSkip,
  );
  final hide = inputs.hideMedicationNames;
  final rendered = <RenderedReminder>[];
  for (final request in plan.requests) {
    // Every request comes from one of the targets.
    final target = inputs.targets[request.scheduleId];
    if (target == null) {
      continue;
    }
    final content = reminderContent(
      strings,
      target,
      request,
      hideMedicationNames: hide,
    );
    final applied = AppliedNotification(
      request,
      displayFingerprint: displayFingerprint(
        level: request.level,
        exact: exact,
        privacy: target.privacy,
        hideMedicationNames: hide,
        locale: locale.toLanguageTag(),
        title: content.title,
        body: content.body,
      ),
      scheduleFingerprint: target.scheduleFingerprint,
    );
    rendered.add(
      RenderedReminder(
        applied,
        _reminder(request, content, actions, exact: exact),
      ),
    );
  }
  return rendered;
}

ScheduledReminder _reminder(
  NotificationRequest request,
  ReminderContent content,
  ReminderActionTitles actions, {
  required bool exact,
}) {
  return ScheduledReminder(
    id: request.id,
    fireAtUtc: request.fireAtUtc,
    level: request.level,
    exact: exact,
    title: content.title,
    body: content.body,
    payload: ReminderPayload(
      occurrenceKey: request.occurrenceKey,
      medicationId: request.medicationId,
    ).encode(),
    threadId: occurrenceThreadId(request.occurrenceKey),
    actions: actions,
  );
}
