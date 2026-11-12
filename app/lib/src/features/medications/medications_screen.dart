import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../catalog/catalog_providers.dart';
import '../common/gap.dart';
import '../common/local_time.dart';
import '../common/status_message.dart';
import '../doses/dose_providers.dart';
import '../doses/scheduled_doses.dart';
import '../family/add_medication_route.dart';
import '../family/archived_profile_banner.dart';
import '../family/profile_context.dart';
import '../history/history_providers.dart';
import '../shell/empty_state.dart';
import 'medication_card.dart';
import 'medications_header.dart';
import 'medications_scan_button.dart';

/// The medications of a profile; tap to edit, «+» to add, «Scan» to add by
/// barcode (only where a catalog exists).
///
/// As a tab it shows the profile chosen with the profile button (the user's
/// own by default); with a [profileId] it is that profile's list, pushed
/// above the tabs. What can be edited follows the role (ADR 0005 §2): viewers
/// see the list only, editors change `shared` medications only, and a
/// redacted (`anonymous`) medication of someone else's shows no name or
/// dose. An empty list offers the scan and the manual form itself, and has
/// no «+» and no floating button (board B2-EmptyMedications).
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
    final rows = medications.valueOrNull;
    final empty = rows != null && rows.isEmpty;
    // The floating button is for a list; an empty one has the scan itself,
    // and a list that is still loading shows neither (no button that comes
    // and goes).
    final showScan = scanRoute != null && rows != null && rows.isNotEmpty;
    final top = [
      MedicationsHeader(
        title: other == null
            ? l10n.medicationsTitle
            : l10n.medicationsOf(other.profile.displayName),
        pushed: profileId != null,
        // No «+» while loading or when the empty state offers the action.
        addRoute: rows == null || rows.isEmpty ? null : addRoute,
      ),
      const Gap.v(PillPalSpacing.md),
      if (access != null && access.archived)
        ArchivedProfileBanner(access: access),
    ];
    return Scaffold(
      floatingActionButton: showScan
          ? MedicationsScanButton(
              key: const Key('medications-scan'),
              onPressed: () => context.push(scanRoute),
            )
          : null,
      body: SafeArea(
        child: empty
            // The empty state takes what the header leaves and centres in it
            // (board B2-EmptyMedications); it scrolls itself if the text is
            // too large for the space.
            ? Padding(
                padding: PillPalSpacing.tabHeader,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ...top,
                    Expanded(child: _empty(context, addRoute, scanRoute)),
                  ],
                ),
              )
            : ListView(
                // The scan button floats over the bottom: leave room for it.
                padding: showScan
                    ? PillPalSpacing.tabHeader.copyWith(
                        bottom: PillPalSizes.fabClearance,
                      )
                    : PillPalSpacing.tabHeader,
                children: [
                  ...top,
                  ...medications.when(
                    skipLoadingOnReload: true,
                    loading: () => const [
                      Center(child: CircularProgressIndicator()),
                    ],
                    error: (error, stack) => [
                      StatusMessage(
                        icon: Icons.error_outline,
                        text: l10n.errorGeneric,
                      ),
                    ],
                    data: (rows) => [
                      _MedicationList(
                        medications: rows,
                        profileId: shown,
                        access: access,
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  /// No medications: the hint, and the actions when the role allows them:
  /// scan and «add manually», or just «add» without a catalog.
  Widget _empty(BuildContext context, String? addRoute, String? scanRoute) {
    final l10n = AppLocalizations.of(context);
    final String message;
    if (addRoute == null) {
      message = l10n.relativeNoMedications;
    } else if (scanRoute == null) {
      message = l10n.medicationsEmpty;
    } else {
      message = l10n.medicationsEmptyScan;
    }
    return EmptyState(
      icon: Icons.medication_outlined,
      headline: l10n.medicationsEmptyTitle,
      message: message,
      action: switch ((addRoute, scanRoute)) {
        (null, _) => null,
        (final add?, null) => FilledButton.icon(
            key: const Key('medications-add'),
            onPressed: () => context.push(add),
            icon: const Icon(Icons.add),
            label: Text(l10n.addMedication, textAlign: TextAlign.center),
          ),
        (_, final scan?) => FilledButton.icon(
            key: const Key('medications-scan'),
            onPressed: () => context.push(scan),
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(l10n.scanPackageAction, textAlign: TextAlign.center),
          ),
      },
      secondaryAction: switch ((addRoute, scanRoute)) {
        (final add?, _?) => OutlinedButton.icon(
            key: const Key('medications-add'),
            onPressed: () => context.push(add),
            icon: const Icon(Icons.add),
            label: Text(l10n.manualEntry, textAlign: TextAlign.center),
          ),
        _ => null,
      },
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
            MedicationCard(medication: medication, access: access),
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
                MedicationCard(medication: medication, access: access),
                gap,
              ],
            ],
          ),
      ],
    );
  }
}
