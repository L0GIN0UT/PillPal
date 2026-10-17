import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../routing/routes.dart';
import '../../theme/palette.dart';
import '../common/local_time.dart';
import '../doses/dose_providers.dart';
import '../doses/scheduled_doses.dart';
import '../schedule/schedule_text.dart';
import '../shell/empty_state.dart';
import 'medication_form.dart';
import 'medication_providers.dart';

/// The self profile's medications; tap to edit, "+" to add.
class MedicationsScreen extends ConsumerWidget {
  /// Creates the screen.
  const MedicationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final medications = ref.watch(selfMedicationsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.medicationsTitle),
        actions: [
          IconButton(
            key: const Key('medications-add'),
            tooltip: l10n.addMedication,
            icon: const Icon(Icons.add),
            onPressed: () => context.push(AppRoutes.newMedication),
          ),
        ],
      ),
      body: medications.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(child: Text(l10n.errorGeneric)),
        data: (rows) => rows.isEmpty
            ? EmptyState(
                icon: Icons.medication_outlined,
                message: l10n.medicationsEmpty,
                action: FilledButton.icon(
                  onPressed: () => context.push(AppRoutes.newMedication),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.addMedication),
                ),
              )
            : _MedicationList(medications: rows),
      ),
    );
  }
}

/// Running medications, then the archived ones in a collapsed section
/// (ADR 0003 §3: finished medications keep their history).
class _MedicationList extends ConsumerWidget {
  const _MedicationList({required this.medications});

  final List<MedicationRow> medications;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final today = ref.watch(todayDateProvider);
    final schedules = ref.watch(parsedSchedulesProvider).valueOrNull ??
        const <ParsedSchedule>[];
    final rules = <String, List<ScheduleRule>>{};
    for (final schedule in schedules) {
      (rules[schedule.row.medicationId] ??= []).add(schedule.rule);
    }
    bool archived(MedicationRow row) =>
        isArchivedOn(rules[row.id] ?? const [], today);
    final finished = medications.where(archived).toList();
    const gap = SizedBox(height: 10);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        for (final medication in medications)
          if (!archived(medication)) ...[
            _MedicationCard(medication: medication),
            gap,
          ],
        if (finished.isNotEmpty)
          ExpansionTile(
            key: const Key('medications-archived'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text(l10n.archivedSection(finished.length)),
            children: [
              for (final medication in finished) ...[
                _MedicationCard(medication: medication),
                gap,
              ],
            ],
          ),
      ],
    );
  }
}

class _MedicationCard extends ConsumerWidget {
  const _MedicationCard({required this.medication});

  final MedicationRow medication;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final schedules =
        ref.watch(medicationSchedulesProvider(medication.id)).valueOrNull;
    final strength = medication.strengthText;
    final summary = schedules == null || schedules.isEmpty
        ? l10n.noSchedule
        : schedules
            .map((s) => scheduleSummary(l10n, s.rule, locale))
            .join('\n');
    return Card(
      key: ValueKey('medication-${medication.id}'),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => context.push(AppRoutes.medication(medication.id)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strength == null || strength.isEmpty
                          ? medication.name ?? ''
                          : '${medication.name ?? ''} $strength',
                      style: textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(summary, style: textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _PrivacyIcon(privacy: MedicationPrivacy.of(medication.privacy)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrivacyIcon extends StatelessWidget {
  const _PrivacyIcon({required this.privacy});

  final MedicationPrivacy privacy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (IconData icon, String label) = switch (privacy) {
      MedicationPrivacy.shared => (Icons.people_outline, l10n.privacyShared),
      MedicationPrivacy.anonymous => (
          Icons.visibility_off_outlined,
          l10n.privacyAnonymous,
        ),
      MedicationPrivacy.hidden => (Icons.lock_outline, l10n.privacyHidden),
    };
    return Icon(icon, color: context.palette.inkMuted, semanticLabel: label);
  }
}
