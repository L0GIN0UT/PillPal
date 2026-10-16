import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../reminders/providers.dart';
import '../../reminders/reminder_settings.dart';
import 'reminder_level_picker.dart';

/// Default reminder settings for the settings screen (TZ §2.3): on/off and
/// level for every medication without its own settings.
class ReminderDefaultsSection extends ConsumerWidget {
  /// Creates the section.
  const ReminderDefaultsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(reminderDefaultsProvider).valueOrNull ??
        ReminderSettings.builtIn;
    final repository = ref.read(reminderSettingsRepositoryProvider);
    void save(ReminderSettings next) => unawaited(repository.setDefaults(next));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.reminderDefaultsTitle,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        SwitchListTile(
          key: const ValueKey('reminder-defaults-enabled'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.reminderEnabled),
          value: settings.enabled,
          onChanged: (enabled) => save(settings.copyWith(enabled: enabled)),
        ),
        if (settings.enabled)
          ReminderLevelPicker(value: settings, onChanged: save),
      ],
    );
  }
}

/// Reminder settings of one medication for the medication editor: follow
/// the defaults, or its own on/off and level.
class MedicationReminderSection extends ConsumerWidget {
  /// Creates the section for [medicationId].
  const MedicationReminderSection({required this.medicationId, super.key});

  /// The medication.
  final String medicationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final defaults = ref.watch(reminderDefaultsProvider).valueOrNull ??
        ReminderSettings.builtIn;
    final override =
        ref.watch(medicationReminderOverrideProvider(medicationId)).valueOrNull;
    final repository = ref.read(reminderSettingsRepositoryProvider);
    final effective = override ?? defaults;
    void save(ReminderSettings next) =>
        unawaited(repository.setOverride(medicationId, next));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('reminder-use-defaults'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.reminderUseDefaults),
          value: override == null,
          onChanged: (useDefaults) => unawaited(
            useDefaults
                ? repository.clearOverride(medicationId)
                : repository.setOverride(medicationId, defaults),
          ),
        ),
        if (override != null) ...[
          SwitchListTile(
            key: const ValueKey('reminder-enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.reminderEnabled),
            value: override.enabled,
            onChanged: (enabled) => save(override.copyWith(enabled: enabled)),
          ),
          if (override.enabled)
            ReminderLevelPicker(value: effective, onChanged: save),
        ],
      ],
    );
  }
}
