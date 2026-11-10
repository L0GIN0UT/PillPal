import 'package:flutter/material.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../reminders/reminder_settings.dart';
import '../../theme/spacing.dart';
import '../common/choice_group.dart';
import '../common/gap.dart';
import '../common/group_label.dart';

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final level in ReminderLevel.values)
          // One choice out of four: screen readers announce a radio group.
          Semantics(
            inMutuallyExclusiveGroup: true,
            checked: value.level == level,
            child: ListTile(
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
          ),
        if (value.level.repeats) ...[
          const Gap.v(PillPalSpacing.md),
          GroupLabel(l10n.reminderRepeatEvery),
          ChoiceGroup<int>(
            options: _labelled(
              _withCurrent(repeatIntervalChoices, value.repeatEveryMinutes),
              l10n.reminderRepeatMinutes,
            ),
            selected: value.repeatEveryMinutes,
            keyOf: (minutes) => ValueKey('reminder-interval-$minutes'),
            onSelected: (minutes) =>
                onChanged(value.copyWith(repeatEveryMinutes: minutes)),
          ),
          const Gap.v(PillPalSpacing.md),
          GroupLabel(l10n.reminderMaxRepeats),
          ChoiceGroup<int>(
            options: _labelled(
              _withCurrent(maxRepeatsChoices, value.maxRepeats),
              l10n.reminderTimes,
            ),
            selected: value.maxRepeats,
            keyOf: (count) => ValueKey('reminder-repeats-$count'),
            onSelected: (count) => onChanged(value.copyWith(maxRepeats: count)),
          ),
        ],
      ],
    );
  }

  static Map<int, String> _labelled(
    List<int> values,
    String Function(int) label,
  ) =>
      {for (final item in values) item: label(item)};

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
