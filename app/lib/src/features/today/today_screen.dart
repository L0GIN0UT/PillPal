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
import '../shell/empty_state.dart';
import 'dose_tile.dart';
import 'today_senior.dart';
import 'today_state.dart';
import 'today_widgets.dart';

/// Today's doses (mockups "Today" and "TodaySenior").
///
/// Syncs on open, on resume and on pull-to-refresh; refreshes "now" every
/// minute so pending doses turn missed without user action.
class TodayScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const TodayScreen({super.key});

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
    final today = ref.watch(todayProvider);
    final senior = ref.watch(settingsProvider).seniorMode;
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
              _Header(date: today.valueOrNull?.date),
              const SizedBox(height: 18),
              ...today.when(
                data: (state) => _content(context, state, senior),
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

  List<Widget> _content(BuildContext context, TodayState state, bool senior) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    if (!state.hasMedications) {
      return [
        EmptyState(
          icon: Icons.medication_outlined,
          message: l10n.todayEmpty,
          action: FilledButton.icon(
            onPressed: () => context.push(AppRoutes.newMedication),
            icon: const Icon(Icons.add),
            label: Text(l10n.addMedication),
          ),
        ),
      ];
    }
    const gap = SizedBox(height: 10);
    return [
      if (state.doses.isEmpty)
        Text(l10n.todayNoDoses, style: textTheme.bodyLarge)
      else if (senior)
        SeniorTodayContent(state: state)
      else ...[
        TodaySummaryCard(state: state),
        const SizedBox(height: 18),
        for (final dose in state.doses) ...[
          DoseTile(key: ValueKey(dose.occurrence.key), dose: dose),
          gap,
        ],
      ],
      for (final item in state.lowStock) ...[
        gap,
        LowStockBanner(item: item),
      ],
      if (state.asNeeded.isNotEmpty) ...[
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
  const _Header({required this.date});

  final LocalDate? date;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final day = date;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (day != null)
                Text(
                  formatLongDate(day, locale),
                  style: textTheme.bodySmall,
                ),
              Text(l10n.todayTitle, style: textTheme.headlineLarge),
            ],
          ),
        ),
        IconButton(
          tooltip: l10n.settingsTitle,
          iconSize: 26,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => context.push(AppRoutes.settings),
        ),
        const SizedBox(width: 4),
        IconButton.filled(
          key: const Key('today-add'),
          tooltip: l10n.addMedication,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          style: IconButton.styleFrom(
            backgroundColor: palette.action,
            foregroundColor: palette.onAction,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          icon: const Icon(Icons.add),
          onPressed: () => context.push(AppRoutes.newMedication),
        ),
      ],
    );
  }
}
