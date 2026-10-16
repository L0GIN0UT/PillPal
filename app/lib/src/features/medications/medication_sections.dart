import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../schedule/schedule_text.dart';
import '../common/choice_button.dart';
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
          if (entry.key != MedicationPrivacy.shared) const SizedBox(width: 8),
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

/// Scan and catalog entry points, disabled until Phase 4.
class CatalogSoonSection extends StatelessWidget {
  /// Creates the section.
  const CatalogSoonSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          key: const Key('med-scan'),
          onPressed: null,
          icon: const Icon(Icons.qr_code_scanner),
          label: Text(l10n.scanPackage),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('med-catalog'),
          enabled: false,
          decoration: InputDecoration(
            labelText: l10n.catalogSearch,
            prefixIcon: const Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 6),
        Text(l10n.catalogSoon, style: textTheme.bodySmall),
      ],
    );
  }
}

/// Schedules of an existing medication with an "add schedule" button.
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
    final schedules =
        ref.watch(medicationSchedulesProvider(medicationId)).valueOrNull ??
            const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.schedulesSection, style: textTheme.titleMedium),
        const SizedBox(height: 8),
        if (schedules.isEmpty)
          Text(l10n.noSchedule, style: textTheme.bodySmall),
        for (final schedule in schedules)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              key: ValueKey('schedule-${schedule.row.id}'),
              child: ListTile(
                title: Text(scheduleSummary(l10n, schedule.rule, locale)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(
                  AppRoutes.schedule(medicationId, schedule.row.id),
                ),
              ),
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('schedule-add'),
          onPressed: () => context.push(AppRoutes.newSchedule(medicationId)),
          icon: const Icon(Icons.add),
          label: Text(l10n.addSchedule),
        ),
      ],
    );
  }
}
