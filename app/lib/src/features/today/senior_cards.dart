import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/repositories/dose_events_repository.dart';
import '../../theme/palette.dart';
import '../common/error_snack_bar.dart';
import '../common/local_time.dart';
import '../doses/dose_providers.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';
import 'dose_tile.dart';
import 'today_senior.dart';

/// Localized status of a dose ("Taken", "Missed", ...).
String doseStatusText(AppLocalizations l10n, DoseStatus status) {
  switch (status) {
    case DoseStatus.taken:
      return l10n.statusTaken;
    case DoseStatus.skipped:
      return l10n.statusSkipped;
    case DoseStatus.missed:
      return l10n.statusMissed;
    case DoseStatus.pending:
      return l10n.statusPending;
  }
}

/// Icon, colours and label of a group of doses at one time.
class GroupStatus {
  /// Creates a status.
  const GroupStatus({
    required this.icon,
    required this.background,
    required this.foreground,
    required this.label,
  });

  /// Icon (colour is never the only signal).
  final IconData icon;

  /// Square fill.
  final Color background;

  /// Icon colour.
  final Color foreground;

  /// Text for screen readers.
  final String label;
}

/// All taken, any missed, or pending.
GroupStatus groupStatus(
  AppLocalizations l10n,
  PillPalPalette palette,
  List<ScheduledDose> doses,
) {
  if (doses.every((d) => d.status == DoseStatus.taken)) {
    return GroupStatus(
      icon: Icons.check_rounded,
      background: palette.taken,
      foreground: palette.onTaken,
      label: l10n.statusTaken,
    );
  }
  if (doses.any((d) => d.status == DoseStatus.missed)) {
    return GroupStatus(
      icon: Icons.priority_high_rounded,
      background: palette.missed,
      foreground: palette.onMissed,
      label: l10n.statusMissed,
    );
  }
  return GroupStatus(
    icon: Icons.schedule,
    background: palette.border,
    foreground: palette.ink,
    label: l10n.statusPending,
  );
}

/// The coloured square with the status icon.
class StatusSquare extends StatelessWidget {
  /// Creates the square.
  const StatusSquare({required this.status, super.key});

  /// The status shown.
  final GroupStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: status.background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(status.icon, color: status.foreground, size: 28),
    );
  }
}

/// The large card of the dose to take now: take, skip, remind later.
class SeniorNowCard extends ConsumerWidget {
  /// Creates the card.
  const SeniorNowCard({
    required this.dose,
    required this.due,
    required this.onTake,
    required this.onSkip,
    super.key,
  });

  /// The dose.
  final ScheduledDose dose;

  /// Whether it is due already ("take now") or later ("next").
  final bool due;

  /// "Take" tapped.
  final VoidCallback onTake;

  /// "Skip" tapped.
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final key = dose.occurrence.key;
    final busy = ref.watch(
      doseWritesInFlightProvider.select((keys) => keys.contains(key)),
    );
    final name = medicationTitle(dose);
    final time = doseTime(dose, ref.watch(deviceTimeZoneProvider));
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
          Text(name, style: textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(
            '${doseDetail(context, dose)} · $time',
            style: textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          _NowActions(
            dose: dose,
            busy: busy,
            name: name,
            time: time,
            onTake: onTake,
            onSkip: onSkip,
          ),
        ],
      ),
    );
  }
}

/// Take (large), skip and remind later.
class _NowActions extends ConsumerWidget {
  const _NowActions({
    required this.dose,
    required this.busy,
    required this.name,
    required this.time,
    required this.onTake,
    required this.onSkip,
  });

  final ScheduledDose dose;
  final bool busy;
  final String name;
  final String time;
  final VoidCallback onTake;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          key: ValueKey('dose-take-${dose.occurrence.key}'),
          style: FilledButton.styleFrom(minimumSize: const Size(64, 76)),
          onPressed: busy ? null : onTake,
          child: Text(
            l10n.takeAction,
            semanticsLabel: l10n.doseTakeLabel(name, time),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const Key('senior-skip'),
          onPressed: busy ? null : onSkip,
          child: Text(
            l10n.skipAction,
            semanticsLabel: l10n.doseSkipLabel(name, time),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const Key('senior-snooze'),
          onPressed: busy
              ? null
              : () {
                  runShowingErrors(
                    context,
                    ref.read(doseActionsProvider).snooze(dose),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.snoozedNote)),
                  );
                },
          child: Text(l10n.snoozeAction(DoseTiming.snooze.inMinutes)),
        ),
      ],
    );
  }
}

/// "Taken ✓ · Undo" for a moment after a mark on the "now" card.
class SeniorConfirmationCard extends ConsumerWidget {
  /// Creates the card.
  const SeniorConfirmationCard({
    required this.confirmation,
    required this.onUndo,
    super.key,
  });

  /// The mark just made.
  final SeniorConfirmation confirmation;

  /// "Undo" tapped.
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final dose = confirmation.dose;
    final taken = confirmation.type == DoseEventType.taken;
    final name = medicationTitle(dose);
    final time = doseTime(dose, ref.watch(deviceTimeZoneProvider));
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: const Key('senior-confirmation'),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: taken ? palette.taken : palette.border,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  taken ? Icons.check_circle : Icons.remove_circle_outline,
                  color: taken ? palette.taken : palette.ink,
                  size: 40,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    taken ? l10n.seniorConfirmTaken : l10n.statusSkipped,
                    style: textTheme.headlineSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('$name · $time', style: textTheme.bodyLarge),
            const SizedBox(height: 16),
            OutlinedButton(
              key: const Key('senior-undo'),
              onPressed: onUndo,
              child: Text(
                l10n.undoShort,
                semanticsLabel: l10n.undoMarkLabel(name, time),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Everything for today is marked.
class SeniorAllDoneCard extends StatelessWidget {
  /// Creates the card.
  const SeniorAllDoneCard({super.key});

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
