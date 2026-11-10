import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import '../catalog/catalog_providers.dart';
import '../common/gap.dart';
import '../common/local_time.dart';
import '../common/pillpal_icon_button.dart';
import '../doses/dose_providers.dart';
import '../doses/scheduled_doses.dart';
import '../family/add_medication_route.dart';
import '../family/archived_profile_banner.dart';
import '../family/profile_context.dart';
import '../family/profile_switcher.dart';
import '../history/history_providers.dart';
import '../schedule/schedule_text.dart';
import '../shell/empty_state.dart';
import 'medication_form.dart';
import 'medication_providers.dart';
import 'medications_scan_button.dart';

/// The medications of a profile; tap to edit, "+" to add, "Scan" to add by
/// barcode (only where a catalog exists).
///
/// As a tab it shows the profile chosen with the switcher (the user's own by
/// default); with a [profileId] it is that profile's list, pushed above the
/// tabs. What can be edited follows the role (ADR 0005 §2): viewers see the
/// list only, editors change `shared` medications only, and a redacted
/// (`anonymous`) medication of someone else's shows no name or dose.
class MedicationsScreen extends ConsumerWidget {
  /// Creates the screen.
  const MedicationsScreen({this.profileId, super.key});

  /// The profile of a pushed screen; null for the tab.
  final String? profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final shown = profileId ?? ref.watch(selectedProfileIdProvider);
    final access = ref.watch(profileAccessProvider(shown)).valueOrNull;
    final medications = ref.watch(profileMedicationsProvider(shown));
    final addRoute = addMedicationRoute(access, ownProfile: shown == null);
    final other = access != null && !access.isOwnSelf ? access : null;
    final scanRoute = addRoute != null && ref.watch(catalogEnabledProvider)
        ? scanEntryRoute(addRoute)
        : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          other == null
              ? l10n.medicationsTitle
              : l10n.medicationsOf(other.profile.displayName),
        ),
        actions: [
          if (addRoute != null)
            PillPalIconButton(
              key: const Key('medications-add'),
              tooltip: l10n.addMedication,
              icon: Icons.add,
              onPressed: () => context.push(addRoute),
            ),
        ],
      ),
      floatingActionButton: scanRoute == null
          ? null
          : MedicationsScanButton(
              key: const Key('medications-scan'),
              onPressed: () => context.push(scanRoute),
            ),
      body: medications.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(child: Text(l10n.errorGeneric)),
        data: (rows) => ListView(
          // The scan button floats over the bottom: leave room for it.
          padding: scanRoute == null
              ? PillPalSpacing.screen
              : PillPalSpacing.screen.copyWith(
                  bottom: PillPalSpacing.xxxl * 3,
                ),
          children: [
            if (profileId == null) const ProfileSwitcher(),
            if (access != null && access.archived)
              ArchivedProfileBanner(access: access),
            if (rows.isEmpty)
              _empty(context, addRoute)
            else
              _MedicationList(
                medications: rows,
                profileId: shown,
                access: access,
              ),
          ],
        ),
      ),
    );
  }

  /// No medications: the hint, and the add button when the role allows it.
  Widget _empty(BuildContext context, String? addRoute) {
    final l10n = AppLocalizations.of(context);
    return SizedBox(
      height: PillPalSizes.emptyStateMinHeight,
      child: EmptyState(
        icon: Icons.medication_outlined,
        message: addRoute == null
            ? l10n.relativeNoMedications
            : l10n.medicationsEmpty,
        action: addRoute == null
            ? null
            : FilledButton.icon(
                onPressed: () => context.push(addRoute),
                icon: const Icon(Icons.add),
                label: Text(l10n.addMedication),
              ),
      ),
    );
  }
}

/// Running medications, then the archived ones in a collapsed section
/// (ADR 0003 §3: finished medications keep their history).
class _MedicationList extends ConsumerWidget {
  const _MedicationList({
    required this.medications,
    required this.profileId,
    required this.access,
  });

  final List<MedicationRow> medications;
  final String? profileId;
  final ProfileAccess? access;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final zone = ref.watch(historyZoneProvider(profileId));
    final today = localDateOf(ref.watch(nowProvider), zone);
    final schedules =
        ref.watch(profileSchedulesProvider(profileId)).valueOrNull ??
            const <ParsedSchedule>[];
    final rules = <String, List<ScheduleRule>>{};
    for (final schedule in schedules) {
      (rules[schedule.row.medicationId] ??= []).add(schedule.rule);
    }
    bool archived(MedicationRow row) =>
        isArchivedOn(rules[row.id] ?? const [], today);
    final finished = medications.where(archived).toList();
    const gap = Gap.v(PillPalSpacing.listGap);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final medication in medications)
          if (!archived(medication)) ...[
            _MedicationCard(medication: medication, access: access),
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
                _MedicationCard(medication: medication, access: access),
                gap,
              ],
            ],
          ),
      ],
    );
  }
}

class _MedicationCard extends ConsumerWidget {
  const _MedicationCard({required this.medication, required this.access});

  final MedicationRow medication;
  final ProfileAccess? access;

  /// Fail closed: nothing opens until the role on the profile is known.
  bool get _canEdit {
    final role = access;
    if (role == null) {
      return false;
    }
    return role.canEditMedication(
      privacy: medication.privacy,
      redacted: medication.redacted,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final schedules =
        ref.watch(medicationSchedulesProvider(medication.id)).valueOrNull;
    // Never the strength of a redacted medication, whatever the row holds.
    final strength = medication.redacted ? null : medication.strengthText;
    final name =
        medication.redacted ? l10n.redactedMedication : (medication.name ?? '');
    final summary = schedules == null || schedules.isEmpty
        ? l10n.noSchedule
        : schedules
            .map((s) => scheduleSummary(l10n, s.rule, locale))
            .join('\n');
    return Card(
      key: ValueKey('medication-${medication.id}'),
      child: InkWell(
        borderRadius: PillPalRadius.card,
        onTap: _canEdit
            ? () => context.push(AppRoutes.medication(medication.id))
            : null,
        child: Padding(
          padding: PillPalSpacing.card,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strength == null || strength.isEmpty
                          ? name
                          : '$name $strength',
                      style: textTheme.titleMedium,
                    ),
                    const Gap.v(PillPalSpacing.xs),
                    Text(summary, style: textTheme.bodySmall),
                  ],
                ),
              ),
              const Gap.h(PillPalSpacing.sm),
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
