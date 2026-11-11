import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../../settings/app_settings.dart';
import '../../theme/spacing.dart';
import '../auth/auth_session.dart';
import '../common/gap.dart';
import '../common/local_time.dart';
import '../common/now_ticker.dart';
import '../common/pillpal_banner.dart';
import '../common/pillpal_card.dart';
import '../common/section_header.dart';
import '../doses/scheduled_doses.dart';
import '../family/add_medication_route.dart';
import '../family/archived_profile_banner.dart';
import '../family/profile_chips_bar.dart';
import '../family/profile_context.dart';
import '../family/profile_note.dart';
import '../reminders/level_migrated_banner.dart';
import '../reminders/reminder_permission_card.dart';
import '../shell/empty_state.dart';
import 'dose_tile.dart';
import 'today_header.dart';
import 'today_senior.dart';
import 'today_state.dart';
import 'today_widgets.dart';

/// Today's doses (mockups "Today" and "TodaySenior").
///
/// As a tab it shows the profile chosen with the chips (the user's own by
/// default). With a [profileId] it is the day view of that profile, pushed
/// above the tabs: a relative's day. Viewers and editors only see statuses:
/// no mark buttons (D3). Syncs on open, on resume and on pull-to-refresh;
/// refreshes "now" every minute so pending doses turn missed without user
/// action.
class TodayScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const TodayScreen({this.profileId, super.key});

  /// The profile of a pushed day view; null for the tab.
  final String? profileId;

  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen> {
  AppLifecycleListener? _lifecycle;
  late final NowTicker _ticker = ref.read(nowTickerProvider);

  @override
  void initState() {
    super.initState();
    // A dose turns "missed" with time alone: re-read "now" every minute.
    _ticker.attach();
    // The app root refreshes "now" and the zone on resume.
    _lifecycle = AppLifecycleListener(onResume: () => requestSync(ref));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        requestSync(ref);
      }
    });
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _ticker.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pushed = widget.profileId != null;
    final shown = widget.profileId ?? ref.watch(selectedProfileIdProvider);
    final own = shown == null;
    final access = ref.watch(profileAccessProvider(shown)).valueOrNull;
    final today = ref.watch(todayStateProvider(shown));
    final senior = ref.watch(settingsProvider).seniorMode;
    // Another person's profile (a relative's, or one the user runs).
    final other = access != null && !access.isOwnSelf ? access : null;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () {
            refreshNowAndZone(ref);
            return ref.read(syncTriggerProvider)();
          },
          child: ListView(
            key: const Key('today-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: PillPalSpacing.tabHeader,
            children: [
              TodayHeader(
                date: today.valueOrNull?.date,
                title: other?.profile.displayName ?? l10n.todayTitle,
                pushed: pushed,
                addRoute: addMedicationRoute(access, ownProfile: own),
                progress: _progress(today.valueOrNull),
              ),
              const Gap.v(PillPalSpacing.md),
              if (!pushed) const ProfileChipsBar(),
              if (access != null && access.archived)
                ArchivedProfileBanner(access: access),
              if (other != null) ProfileNote(access: other),
              if (pushed && access != null) _DayLinks(profileId: access.id),
              // Permission and battery notices; nothing when reminders work.
              if (other == null) const ReminderPermissionCard(),
              if (other == null) const LevelMigratedBanner(),
              const Gap.v(PillPalSpacing.sm),
              ...today.when(
                skipLoadingOnReload: true,
                data: (state) =>
                    _content(context, state, senior, access, own: own),
                loading: () => const [
                  Center(child: CircularProgressIndicator()),
                ],
                error: (error, stack) => [Text(l10n.errorGeneric)],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Taken of all doses, for the ring; nothing to count without doses.
  TodayProgress? _progress(TodayState? state) =>
      state == null || state.doses.isEmpty
          ? null
          : (done: state.takenCount, total: state.doses.length);

  /// No medications: the hint, and the add button when the role allows it.
  Widget _emptyState(BuildContext context, String? addRoute) {
    final l10n = AppLocalizations.of(context);
    return EmptyState(
      icon: Icons.medication_outlined,
      message: addRoute == null ? l10n.relativeNoMedications : l10n.todayEmpty,
      action: addRoute == null
          ? null
          : FilledButton.icon(
              onPressed: () => context.push(addRoute),
              icon: const Icon(Icons.add),
              label: Text(l10n.addMedication),
            ),
    );
  }

  List<Widget> _content(
    BuildContext context,
    TodayState state,
    bool senior,
    ProfileAccess? access, {
    required bool own,
  }) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    // Fail closed: another profile has no mark button until its role is
    // known; the own one has no role to wait for before the first pull.
    final canMark = access?.canMarkDoses ?? own;
    final addRoute = addMedicationRoute(access, ownProfile: own);
    if (!state.hasMedications) {
      return [_emptyState(context, addRoute)];
    }
    const gap = Gap.v(PillPalSpacing.md);
    return [
      if (state.doses.isEmpty)
        Text(l10n.todayNoDoses, style: textTheme.bodyLarge)
      else if (senior && canMark)
        SeniorTodayContent(state: state)
      else
        ..._doseSections(context, state, canMark: canMark),
      // Stock is the owner's business: a relative's day view never shows
      // it (it also is not tracked for other profiles).
      if (canMark)
        for (final item in state.lowStock) ...[
          gap,
          LowStockBanner(item: item),
        ],
      if (canMark && state.asNeeded.isNotEmpty) ...[
        SectionHeader(l10n.asNeededSection),
        for (final item in state.asNeeded) ...[
          AsNeededTile(item: item),
          gap,
        ],
      ],
    ];
  }

  /// The «Сейчас» card, «Дальше» and «Уже было» (B2-README section 8).
  List<Widget> _doseSections(
    BuildContext context,
    TodayState state, {
    required bool canMark,
  }) {
    final l10n = AppLocalizations.of(context);
    final sections = todaySections(state, withHero: canMark);
    final hero = sections.hero;
    DoseTile tile(ScheduledDose dose, DoseTileLayout layout) => DoseTile(
          key: ValueKey(dose.occurrence.key),
          dose: dose,
          canMark: canMark,
          layout: layout,
          due: !dose.dueAt.isAfter(state.now),
        );
    return [
      if (hero != null)
        tile(hero, DoseTileLayout.hero)
      else if (state.takenCount == state.doses.length)
        PillPalBanner(
          key: const Key('today-all-taken'),
          icon: Icons.check_circle_outline,
          title: l10n.todayAllTaken,
        ),
      if (sections.upcoming.isNotEmpty) ...[
        SectionHeader(l10n.todayNext),
        PillPalCard.rows(
          key: const Key('today-upcoming'),
          rows: [
            for (final dose in sections.upcoming)
              tile(dose, DoseTileLayout.upcoming),
          ],
        ),
      ],
      if (sections.past.isNotEmpty) ...[
        SectionHeader(l10n.todayEarlier),
        PillPalCard.rows(
          key: const Key('today-earlier'),
          rows: [
            for (final dose in sections.past) tile(dose, DoseTileLayout.past),
          ],
        ),
      ],
    ];
  }
}

/// Medications and history of the profile whose day is shown.
class _DayLinks extends StatelessWidget {
  const _DayLinks({required this.profileId});

  final String profileId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.md),
      child: Wrap(
        spacing: PillPalSpacing.sm,
        runSpacing: PillPalSpacing.sm,
        children: [
          OutlinedButton.icon(
            key: const Key('day-medications'),
            onPressed: () => unawaited(
              context.push(AppRoutes.profileMedications(profileId)),
            ),
            icon: const Icon(Icons.medication_outlined),
            label: Text(l10n.navMedications),
          ),
          OutlinedButton.icon(
            key: const Key('day-history'),
            onPressed: () => unawaited(
              context.push(AppRoutes.profileHistory(profileId)),
            ),
            icon: const Icon(Icons.calendar_month_outlined),
            label: Text(l10n.navHistory),
          ),
        ],
      ),
    );
  }
}
