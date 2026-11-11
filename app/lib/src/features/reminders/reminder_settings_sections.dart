import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../reminders/providers.dart';
import '../../reminders/reminder_settings.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../common/group_label.dart';
import 'reminder_level_picker.dart';

/// The app-wide reminder settings of the settings screen (TZ §2.3, redesign
/// Q2): on/off and level for every medication, and the device setting that
/// hides medication names in notifications (ADR 0001 §8).
class ReminderDefaultsSection extends ConsumerWidget {
  /// Creates the section.
  const ReminderDefaultsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(reminderDefaultsProvider).valueOrNull ??
        ReminderSettings.builtIn;
    final hideNames = ref.watch(reminderHideNamesProvider).valueOrNull ?? false;
    final repository = ref.read(reminderSettingsRepositoryProvider);
    void save(ReminderSettings next) => unawaited(repository.setDefaults(next));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupLabel(l10n.reminderDefaultsTitle),
        SwitchListTile(
          key: const ValueKey('reminder-defaults-enabled'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.reminderEnabled),
          value: settings.enabled,
          onChanged: (enabled) => save(settings.copyWith(enabled: enabled)),
        ),
        if (settings.enabled)
          ReminderLevelPicker(value: settings, onChanged: save),
        const Gap.v(PillPalSpacing.md),
        SwitchListTile(
          key: const ValueKey('reminder-hide-names'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.reminderHideNames),
          subtitle: Text(l10n.reminderHideNamesHint),
          value: hideNames,
          onChanged: (hide) =>
              unawaited(repository.setHideMedicationNames(hide: hide)),
        ),
      ],
    );
  }
}
