import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/palette.dart';
import '../common/local_time.dart';
import '../doses/dose_providers.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';
import 'dose_tile.dart';
import 'today_state.dart';

/// Senior-mode Today (mockup "TodaySenior"): one large card for the dose to
/// take now, then the day grouped by time.
class SeniorTodayContent extends ConsumerWidget {
  /// Creates the content.
  const SeniorTodayContent({required this.state, super.key});

  /// Today's state.
  final TodayState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = state.currentDose;
    final tz = ref.watch(deviceTimeZoneProvider);
    final groups = <String, List<ScheduledDose>>{};
    for (final dose in state.doses) {
      if (identical(dose, current)) {
        continue;
      }
      (groups[doseTime(dose, tz)] ??= <ScheduledDose>[]).add(dose);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (current != null)
          _NowCard(dose: current, due: !current.dueAt.isAfter(state.now))
        else if (state.doses.isNotEmpty)
          const _AllDoneCard(),
        for (final entry in groups.entries) ...[
          const SizedBox(height: 12),
          _TimeGroupRow(time: entry.key, doses: entry.value),
        ],
      ],
    );
  }
}

class _NowCard extends ConsumerWidget {
  const _NowCard({required this.dose, required this.due});

  final ScheduledDose dose;
  final bool due;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final actions = ref.read(doseActionsProvider);
    final tz = ref.watch(deviceTimeZoneProvider);
    return Container(
      key: const Key('senior-now'),
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: palette.action, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            due ? l10n.seniorTakeNow : l10n.seniorNext,
            style: textTheme.titleMedium?.copyWith(color: palette.action),
          ),
          const SizedBox(height: 12),
          Text(medicationTitle(dose), style: textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(
            '${doseDetail(context, dose)} · ${doseTime(dose, tz)}',
            style: textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: ValueKey('dose-take-${dose.occurrence.key}'),
            style: FilledButton.styleFrom(minimumSize: const Size(64, 76)),
            onPressed: () => runDoseAction(actions.take(dose)),
            child: Text(l10n.takeAction),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            key: const Key('senior-snooze'),
            onPressed: () {
              runDoseAction(actions.snooze(dose));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.snoozedNote)),
              );
            },
            child: Text(l10n.snoozeAction(DoseTiming.snooze.inMinutes)),
          ),
        ],
      ),
    );
  }
}

class _AllDoneCard extends StatelessWidget {
  const _AllDoneCard();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: palette.taken, size: 40),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              AppLocalizations.of(context).todayAllTaken,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimeGroupRow extends StatelessWidget {
  const _TimeGroupRow({required this.time, required this.doses});

  final String time;
  final List<ScheduledDose> doses;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final allTaken = doses.every((d) => d.status == DoseStatus.taken);
    final anyMissed = doses.any((d) => d.status == DoseStatus.missed);
    final (
      IconData icon,
      Color background,
      Color foreground,
      String label
    ) = allTaken
        ? (
            Icons.check_rounded,
            palette.taken,
            palette.onTaken,
            l10n.statusTaken
          )
        : anyMissed
            ? (
                Icons.priority_high_rounded,
                palette.missed,
                palette.onMissed,
                l10n.statusMissed
              )
            : (Icons.schedule, palette.border, palette.ink, l10n.statusPending);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(16),
            ),
            child:
                Icon(icon, color: foreground, size: 28, semanticLabel: label),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(time, style: textTheme.titleLarge),
                Text(
                  allTaken
                      ? l10n.todayAllTakenShort
                      : doses.map(medicationTitle).join(', '),
                  style: textTheme.bodyLarge?.copyWith(color: palette.inkMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
