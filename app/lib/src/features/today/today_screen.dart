import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../../settings/app_settings.dart';
import '../../theme/palette.dart';
import '../auth/auth_session.dart';
import '../common/formatters.dart';
import '../common/local_time.dart';
import '../doses/dose_status.dart';
import '../family/add_medication_route.dart';
import '../family/archived_profile_banner.dart';
import '../family/profile_context.dart';
import '../family/profile_note.dart';
import '../family/profile_switcher.dart';
import '../reminders/reminder_permission_card.dart';
import '../shell/empty_state.dart';
import 'dose_tile.dart';
import 'today_senior.dart';
import 'today_state.dart';
import 'today_widgets.dart';

/// Today's doses (mockups "Today" and "TodaySenior").
///
/// As a tab it shows the profile chosen with the switcher (the user's own by
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
  Timer? _ticker;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      DoseTiming.refreshEvery,
      (_) => ref.invalidate(nowProvider),
    );
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
    _ticker?.cancel();
    _lifecycle?.dispose();
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
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
            children: [
              _Header(
                date: today.valueOrNull?.date,
                title: other?.profile.displayName ?? l10n.todayTitle,
                pushed: pushed,
                addRoute: addMedicationRoute(access, ownProfile: own),
              ),
              const SizedBox(height: 12),
              if (!pushed) const ProfileSwitcher(),
              if (access != null && access.archived)
                ArchivedProfileBanner(access: access),
              if (other != null) ProfileNote(access: other),
              if (pushed && access != null) _DayLinks(profileId: access.id),
              // Permission and battery notices; nothing when reminders work.
              if (other == null) const ReminderPermissionCard(),
              const SizedBox(height: 6),
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
    const gap = SizedBox(height: 10);
    return [
      if (state.doses.isEmpty)
        Text(l10n.todayNoDoses, style: textTheme.bodyLarge)
      else if (senior && canMark)
        SeniorTodayContent(state: state)
      else ...[
        TodaySummaryCard(state: state),
        const SizedBox(height: 18),
        for (final dose in state.doses) ...[
          DoseTile(
            key: ValueKey(dose.occurrence.key),
            dose: dose,
            canMark: canMark,
          ),
          gap,
        ],
      ],
      for (final item in state.lowStock) ...[
        gap,
        LowStockBanner(item: item),
      ],
      if (canMark && state.asNeeded.isNotEmpty) ...[
        const SizedBox(height: 18),
        Text(l10n.asNeededSection, style: textTheme.titleLarge),
        const SizedBox(height: 8),
        for (final item in state.asNeeded) ...[
          AsNeededTile(item: item),
          gap,
        ],
      ],
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.date,
    required this.title,
    required this.pushed,
    required this.addRoute,
  });

  final LocalDate? date;
  final String title;

  /// A pushed day view: a back button instead of the settings button.
  final bool pushed;

  /// Where "+" goes, or null for no "+".
  final String? addRoute;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final route = addRoute;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (pushed)
          IconButton(
            key: const Key('day-back'),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.pop(),
          ),
        Expanded(child: _titleBlock(context)),
        if (!pushed)
          IconButton(
            tooltip: l10n.settingsTitle,
            iconSize: 26,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push(AppRoutes.settings),
          ),
        if (route != null) ...[
          const SizedBox(width: 4),
          _addButton(context, route),
        ],
      ],
    );
  }

  /// The date and the title; a long name wraps instead of overflowing.
  Widget _titleBlock(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final day = date;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (day != null)
          Text(formatLongDate(day, locale), style: textTheme.bodySmall),
        Text(
          title,
          key: const Key('today-title'),
          style: textTheme.headlineLarge,
        ),
      ],
    );
  }

  Widget _addButton(BuildContext context, String route) {
    final palette = context.palette;
    return IconButton.filled(
      key: const Key('today-add'),
      tooltip: AppLocalizations.of(context).addMedication,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      style: IconButton.styleFrom(
        backgroundColor: palette.action,
        foregroundColor: palette.onAction,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      icon: const Icon(Icons.add),
      onPressed: () => context.push(route),
    );
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
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
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
