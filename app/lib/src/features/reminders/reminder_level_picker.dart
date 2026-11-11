import 'package:flutter/material.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../reminders/reminder_settings.dart';
import '../../theme/spacing.dart';
import '../common/card_control_block.dart';
import '../common/choice_group.dart';
import '../common/gap.dart';
import '../common/pillpal_segmented.dart';

/// The levels a segment of the control stands for; the alarm is the switch.
const List<ReminderLevel> _segmentLevels = [
  ReminderLevel.quiet,
  ReminderLevel.normal,
  ReminderLevel.persistent,
];

/// Picks the app-wide reminder level (D3) and, for repeating levels, N
/// (interval) and M (repeats) - TZ §2.3. Three segments (quiet, normal,
/// persistent) and a separate alarm switch map onto the four
/// [ReminderLevel]s: the switch on is `alarm` (the segment then shows
/// persistent), off is `persistent`; a quiet or normal segment while the
/// alarm is on takes that level, which turns the switch off. Stateless: the
/// owner stores the value.
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

  bool get _alarm => value.level == ReminderLevel.alarm;

  // Quiet, then the alarm on, then off again ends at persistent: the switch
  // off is persistent by D3, whatever the level was before the alarm.

  /// The alarm shows as persistent in the segments.
  ReminderLevel get _segment => _alarm ? ReminderLevel.persistent : value.level;

  void _pickSegment(ReminderLevel level) {
    // Persistent while the alarm is on changes nothing: the alarm is the
    // persistent level through another channel.
    if (level == ReminderLevel.persistent && _alarm) {
      return;
    }
    onChanged(value.copyWith(level: level));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The segments show persistent while the alarm is on; say so to screen
        // readers, which cannot see the switch below as part of the choice.
        Semantics(
          key: const Key('reminder-level-segments'),
          container: true,
          value: _alarm ? l10n.reminderLevelAlarm : null,
          child: PillPalSegmented<ReminderLevel>(
            options: {
              for (final level in _segmentLevels)
                level: reminderLevelLabel(l10n, level),
            },
            selected: _segment,
            onChanged: _pickSegment,
            keyOf: (level) => ValueKey('reminder-level-${level.name}'),
          ),
        ),
        // The switch subtitle carries the alarm hint, so none here.
        if (!_alarm) ...[
          const Gap.v(PillPalSpacing.sm),
          Text(
            _hint(l10n, _segment),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        SwitchListTile(
          key: const ValueKey('reminder-level-alarm'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.reminderLevelAlarm),
          subtitle: Text(l10n.reminderLevelAlarmHint),
          value: _alarm,
          onChanged: (on) => onChanged(
            value.copyWith(
              level: on ? ReminderLevel.alarm : ReminderLevel.persistent,
            ),
          ),
        ),
        if (value.level.repeats) ...[
          const Gap.v(PillPalSpacing.md),
          CardControlBlock(
            label: l10n.reminderRepeatEvery,
            padding: EdgeInsets.zero,
            child: ChoiceGroup<int>(
              options: _labelled(
                _withCurrent(repeatIntervalChoices, value.repeatEveryMinutes),
                l10n.reminderRepeatMinutes,
              ),
              selected: value.repeatEveryMinutes,
              keyOf: (minutes) => ValueKey('reminder-interval-$minutes'),
              onSelected: (minutes) =>
                  onChanged(value.copyWith(repeatEveryMinutes: minutes)),
            ),
          ),
          const Gap.v(PillPalSpacing.md),
          CardControlBlock(
            label: l10n.reminderMaxRepeats,
            padding: EdgeInsets.zero,
            child: ChoiceGroup<int>(
              options: _labelled(
                _withCurrent(maxRepeatsChoices, value.maxRepeats),
                l10n.reminderTimes,
              ),
              selected: value.maxRepeats,
              keyOf: (count) => ValueKey('reminder-repeats-$count'),
              onSelected: (count) =>
                  onChanged(value.copyWith(maxRepeats: count)),
            ),
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
