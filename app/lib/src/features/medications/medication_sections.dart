import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../../theme/spacing.dart';
import '../common/choice_button.dart';
import '../common/gap.dart';
import '../common/local_time.dart';
import '../doses/scheduled_doses.dart';
import '../schedule/schedule_text.dart';
import 'medication_form.dart';
import 'medication_providers.dart';

/// "Кому видно": shared / anonymous / hidden.
class PrivacySelector extends StatelessWidget {
  /// Creates the selector.
  const PrivacySelector({
    required this.value,
    required this.onChanged,
    super.key,
  });

  /// Current value.
  final MedicationPrivacy value;

  /// Called with the tapped value.
  final ValueChanged<MedicationPrivacy> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final labels = {
      MedicationPrivacy.shared: l10n.privacyShared,
      MedicationPrivacy.anonymous: l10n.privacyAnonymous,
      MedicationPrivacy.hidden: l10n.privacyHidden,
    };
    return Row(
      children: [
        for (final entry in labels.entries) ...[
          if (entry.key != MedicationPrivacy.shared)
            const Gap.h(PillPalSpacing.sm),
          Expanded(
            child: ChoiceButton(
              key: ValueKey('privacy-${entry.key.wire}'),
              label: entry.value,
              selected: entry.key == value,
              onTap: () => onChanged(entry.key),
            ),
          ),
        ],
      ],
    );
  }
}

/// What the chosen privacy level shows to relatives (TZ §2.5): the plain
/// words next to the selector, so nobody picks `hidden` or `shared` blind.
class PrivacyExplanation extends StatelessWidget {
  /// Creates the explanation of [value].
  const PrivacyExplanation({required this.value, super.key});

  /// The level to explain.
  final MedicationPrivacy value;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = switch (value) {
      MedicationPrivacy.shared => l10n.privacyExplainShared,
      MedicationPrivacy.anonymous => l10n.privacyExplainAnonymous,
      MedicationPrivacy.hidden => l10n.privacyExplainHidden,
    };
    return Text(
      text,
      key: ValueKey('privacy-explain-${value.wire}'),
      style: Theme.of(context).textTheme.bodyMedium,
    );
  }
}

/// The privacy choice with its plain-words explanation, or only the note
/// that the level is the owner's to change (editors never touch it, D3).
class PrivacySection extends StatelessWidget {
  /// Creates the section.
  const PrivacySection({
    required this.value,
    required this.canChange,
    required this.onChanged,
    super.key,
  });

  /// The chosen level.
  final MedicationPrivacy value;

  /// Whether the account may change the level.
  final bool canChange;

  /// Called with the level the user picked.
  final ValueChanged<MedicationPrivacy> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.privacyTitle, style: textTheme.titleMedium),
        const Gap.v(PillPalSpacing.sm),
        if (canChange) ...[
          PrivacySelector(value: value, onChanged: onChanged),
          const Gap.v(PillPalSpacing.sm),
          PrivacyExplanation(value: value),
        ] else
          Text(
            l10n.privacyEditorNote,
            key: const Key('privacy-editor-note'),
            style: textTheme.bodyMedium,
          ),
      ],
    );
  }
}

/// Schedules of an existing medication with an "add schedule" button;
/// ended schedules are listed apart and not edited (ADR 0003 §2).
class SchedulesSection extends ConsumerWidget {
  /// Creates the section.
  const SchedulesSection({required this.medicationId, super.key});

  /// The medication.
  final String medicationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final today = ref.watch(todayDateProvider);
    final schedules =
        ref.watch(medicationSchedulesProvider(medicationId)).valueOrNull ??
            const <ParsedSchedule>[];
    final running = [
      for (final s in schedules)
        if (!hasEndedBy(s.rule, today)) s,
    ];
    final ended = [
      for (final s in schedules)
        if (hasEndedBy(s.rule, today)) s,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.schedulesSection, style: textTheme.titleMedium),
        const Gap.v(PillPalSpacing.sm),
        if (running.isEmpty) Text(l10n.noSchedule, style: textTheme.bodySmall),
        for (final schedule in running)
          _ScheduleCard(
            schedule: schedule,
            title: scheduleSummary(l10n, schedule.rule, locale),
            onTap: () => context.push(
              AppRoutes.schedule(medicationId, schedule.row.id),
            ),
          ),
        const Gap.v(PillPalSpacing.sm),
        OutlinedButton.icon(
          key: const Key('schedule-add'),
          onPressed: () => context.push(AppRoutes.newSchedule(medicationId)),
          icon: const Icon(Icons.add),
          label: Text(l10n.addSchedule),
        ),
        if (ended.isNotEmpty) ...[
          const Gap.v(PillPalSpacing.lg),
          Text(l10n.endedSchedulesSection, style: textTheme.titleSmall),
          const Gap.v(PillPalSpacing.sm),
          for (final schedule in ended)
            _ScheduleCard(
              schedule: schedule,
              title: scheduleSummary(l10n, schedule.rule, locale),
              onTap: null,
            ),
        ],
      ],
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({
    required this.schedule,
    required this.title,
    required this.onTap,
  });

  final ParsedSchedule schedule;
  final String title;

  /// Opens the editor; null for an ended schedule.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.sm),
      child: Card(
        key: ValueKey('schedule-${schedule.row.id}'),
        child: ListTile(
          title: Text(title),
          trailing: onTap == null ? null : const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      ),
    );
  }
}
