import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../reminders/providers.dart';
import '../../reminders/reminder_settings.dart';
import '../../theme/spacing.dart';
import '../common/pillpal_card.dart';
import 'reminder_level_picker.dart';

/// The app-wide reminder settings of the settings screen (TZ §2.3, redesign
/// Q2; board B2-Settings): one card with on/off and level for every
/// medication, and the device setting that hides medication names in
/// notifications (ADR 0001 §8). The screen puts the group header and the
/// permission banners above it.
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
    return PillPalCard.rows(
      rows: [
        SwitchListTile(
          key: const ValueKey('reminder-defaults-enabled'),
          contentPadding: PillPalSpacing.cardRowSide,
          title: Text(l10n.reminderEnabled),
          value: settings.enabled,
          onChanged: (enabled) => save(settings.copyWith(enabled: enabled)),
        ),
        if (settings.enabled)
          Padding(
            padding: PillPalSpacing.cardControl,
            child: ReminderLevelPicker(value: settings, onChanged: save),
          ),
        SwitchListTile(
          key: const ValueKey('reminder-hide-names'),
          contentPadding: PillPalSpacing.cardRowSide,
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
