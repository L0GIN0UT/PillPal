import 'package:flutter/material.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../reminders/reminder_settings.dart';

/// Picks a reminder level and, for repeating levels, N (interval) and M
/// (repeats) - TZ §2.3. Stateless: the owner stores the value.
class ReminderLevelPicker extends StatelessWidget {
  /// Creates the picker.
  const ReminderLevelPicker({
    required this.value,
    required this.onChanged,
    super.key,
  });

  /// Current settings.
  final ReminderSettings value;

  /// Called with the edited settings.
  final ValueChanged<ReminderSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final level in ReminderLevel.values)
          ListTile(
            key: ValueKey('reminder-level-${level.name}'),
            contentPadding: EdgeInsets.zero,
            selected: value.level == level,
            title: Text(reminderLevelLabel(l10n, level)),
            subtitle: Text(_hint(l10n, level)),
            trailing: value.level == level
                ? const Icon(Icons.check_circle)
                : const Icon(Icons.circle_outlined),
            onTap: () => onChanged(value.copyWith(level: level)),
          ),
        if (value.level.repeats) ...[
          const SizedBox(height: 12),
          Text(l10n.reminderRepeatEvery, style: textTheme.titleSmall),
          const SizedBox(height: 8),
          _Choices(
            keyPrefix: 'reminder-interval',
            values:
                _withCurrent(repeatIntervalChoices, value.repeatEveryMinutes),
            selected: value.repeatEveryMinutes,
            label: l10n.reminderRepeatMinutes,
            onSelected: (minutes) =>
                onChanged(value.copyWith(repeatEveryMinutes: minutes)),
          ),
          const SizedBox(height: 12),
          Text(l10n.reminderMaxRepeats, style: textTheme.titleSmall),
          const SizedBox(height: 8),
          _Choices(
            keyPrefix: 'reminder-repeats',
            values: _withCurrent(maxRepeatsChoices, value.maxRepeats),
            selected: value.maxRepeats,
            label: l10n.reminderTimes,
            onSelected: (count) => onChanged(value.copyWith(maxRepeats: count)),
          ),
        ],
      ],
    );
  }

  static String _hint(AppLocalizations l10n, ReminderLevel level) =>
      switch (level) {
        ReminderLevel.quiet => l10n.reminderLevelQuietHint,
        ReminderLevel.normal => l10n.reminderLevelNormalHint,
        ReminderLevel.persistent => l10n.reminderLevelPersistentHint,
        ReminderLevel.alarm => l10n.reminderLevelAlarmHint,
      };

  /// The offered choices plus a stored value that is not among them.
  static List<int> _withCurrent(List<int> choices, int current) =>
      choices.contains(current) ? choices : ([...choices, current]..sort());
}

/// The localized name of [level].
String reminderLevelLabel(AppLocalizations l10n, ReminderLevel level) =>
    switch (level) {
      ReminderLevel.quiet => l10n.reminderLevelQuiet,
      ReminderLevel.normal => l10n.reminderLevelNormal,
      ReminderLevel.persistent => l10n.reminderLevelPersistent,
      ReminderLevel.alarm => l10n.reminderLevelAlarm,
    };

class _Choices extends StatelessWidget {
  const _Choices({
    required this.keyPrefix,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final String keyPrefix;
  final List<int> values;
  final int selected;
  final String Function(int) label;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in values)
          ChoiceChip(
            key: ValueKey('$keyPrefix-$item'),
            label: Text(label(item)),
            selected: item == selected,
            onSelected: (_) => onSelected(item),
          ),
      ],
    );
  }
}
