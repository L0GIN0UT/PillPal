import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../common/error_snack_bar.dart';
import '../common/formatters.dart';
import '../common/local_time.dart';
import '../doses/dose_providers.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';

/// "Метформин 500 мг": name plus strength.
String medicationTitle(ScheduledDose dose) {
  final strength = dose.medication.strengthText;
  return strength == null || strength.isEmpty
      ? dose.medication.name ?? ''
      : '${dose.medication.name ?? ''} $strength';
}

/// What a screen calls a medication: its name and strength, or the generic
/// "Medication" for a redacted (`anonymous`) one of another person's
/// profile, whose name the server never sent.
String doseTitle(AppLocalizations l10n, ScheduledDose dose) =>
    dose.medication.redacted ? l10n.redactedMedication : medicationTitle(dose);

/// Wall-clock time of [dose] (`HH:MM`) in [zone], by default the zone it is
/// shown in ([ScheduledDose.displayZone]).
String doseTime(ScheduledDose dose, [String? zone]) {
  final shown = zone ?? dose.displayZone;
  return dose.zone == shown
      ? dose.occurrence.localTime
      : wallClockOf(dose.dueAt, shown).hhmm;
}

/// "1 таблетка · после еды".
String doseDetail(BuildContext context, ScheduledDose dose) {
  // Never the dose or notes of a redacted medication.
  if (dose.medication.redacted) {
    return '';
  }
  final l10n = AppLocalizations.of(context);
  final locale = Localizations.localeOf(context).toLanguageTag();
  final amount = formatDose(
    l10n,
    dose.occurrence.doseAmount,
    dose.occurrence.doseUnit,
    locale,
  );
  final notes = dose.medication.notes;
  return notes == null || notes.isEmpty ? amount : '$amount · $notes';
}

/// One scheduled dose on Today: time, name, dose and its status or action.
///
/// With [canMark] false (a relative's day view: viewers and editors never
/// mark, D3) the tile only shows the status and opens nothing.
class DoseTile extends ConsumerWidget {
  /// Creates the tile.
  const DoseTile({required this.dose, this.canMark = true, super.key});

  /// The dose.
  final ScheduledDose dose;

  /// Whether the user may mark this dose.
  final bool canMark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final detail = doseDetail(context, dose);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(PillPalSizes.cardRadius),
        onTap: canMark ? () => showDoseActions(context, ref, dose) : null,
        onLongPress: canMark ? () => showDoseActions(context, ref, dose) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          child: Row(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 52),
                child: Text(
                  doseTime(dose),
                  textAlign: TextAlign.center,
                  style: textTheme.titleLarge,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      doseTitle(l10n, dose),
                      style: textTheme.titleMedium,
                    ),
                    if (detail.isNotEmpty)
                      Text(detail, style: textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (canMark)
                DoseStatusAction(dose: dose)
              else
                ReadOnlyDoseStatus(dose: dose),
            ],
          ),
        ),
      ),
    );
  }
}

/// The status of a dose the user may not mark: an icon and a word, never a
/// button.
class ReadOnlyDoseStatus extends StatelessWidget {
  /// Creates the widget.
  const ReadOnlyDoseStatus({required this.dose, super.key});

  /// The dose.
  final ScheduledDose dose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final key = dose.occurrence.key;
    final name = doseTitle(l10n, dose);
    final time = doseTime(dose);
    switch (dose.status) {
      case DoseStatus.taken:
        return _Badge(
          key: ValueKey('dose-status-$key'),
          label: l10n.doseStatusLabel(name, time, l10n.statusTaken),
          icon: Icons.check_rounded,
          background: palette.taken,
          foreground: palette.onTaken,
        );
      case DoseStatus.skipped:
        return _Badge(
          key: ValueKey('dose-status-$key'),
          label: l10n.doseStatusLabel(name, time, l10n.statusSkipped),
          icon: Icons.remove_rounded,
          background: palette.border,
          foreground: palette.ink,
        );
      case DoseStatus.missed:
        return _StatusWord(
          key: ValueKey('dose-status-$key'),
          label: l10n.statusMissed,
          semanticsLabel: l10n.doseMissedLabel(name, time),
          color: palette.missed,
        );
      case DoseStatus.pending:
        return _StatusWord(
          key: ValueKey('dose-status-$key'),
          label: l10n.statusPending,
          semanticsLabel: l10n.doseStatusLabel(name, time, l10n.statusPending),
          color: palette.inkMuted,
        );
    }
  }
}

class _StatusWord extends StatelessWidget {
  const _StatusWord({
    required this.label,
    required this.semanticsLabel,
    required this.color,
    super.key,
  });

  final String label;
  final String semanticsLabel;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      excludeSemantics: true,
      child: Container(
        constraints: BoxConstraints(minHeight: context.metrics.touchTarget),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color, width: 2),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: color,
              ),
        ),
      ),
    );
  }
}

/// The trailing status badge or action button of a dose.
///
/// Pending: "take" right away. Missed: opens the take/skip sheet (a missed
/// dose may have been skipped on purpose). Disabled while a write for the
/// dose is running.
class DoseStatusAction extends ConsumerWidget {
  /// Creates the widget.
  const DoseStatusAction({required this.dose, super.key});

  /// The dose.
  final ScheduledDose dose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final key = dose.occurrence.key;
    final busy = ref.watch(
      doseWritesInFlightProvider.select((keys) => keys.contains(key)),
    );
    final target = Size.square(context.metrics.touchTarget);
    final name = doseTitle(l10n, dose);
    final time = doseTime(dose);
    switch (dose.status) {
      case DoseStatus.taken:
        return _Badge(
          key: ValueKey('dose-taken-$key'),
          label: l10n.doseStatusLabel(name, time, l10n.statusTaken),
          icon: Icons.check_rounded,
          background: palette.taken,
          foreground: palette.onTaken,
        );
      case DoseStatus.skipped:
        return _Badge(
          key: ValueKey('dose-skipped-$key'),
          label: l10n.doseStatusLabel(name, time, l10n.statusSkipped),
          icon: Icons.remove_rounded,
          background: palette.border,
          foreground: palette.ink,
        );
      case DoseStatus.missed:
        return OutlinedButton(
          key: ValueKey('dose-missed-$key'),
          style: OutlinedButton.styleFrom(
            minimumSize: target,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            foregroundColor: palette.missed,
            side: BorderSide(color: palette.missed, width: 2),
          ),
          onPressed: busy ? null : () => showDoseActions(context, ref, dose),
          child: Text(
            l10n.statusMissed,
            semanticsLabel: l10n.doseMissedLabel(name, time),
          ),
        );
      case DoseStatus.pending:
        return FilledButton(
          key: ValueKey('dose-take-$key'),
          style: FilledButton.styleFrom(
            minimumSize: target,
            padding: const EdgeInsets.symmetric(horizontal: 14),
          ),
          onPressed: busy
              ? null
              : () => runShowingErrors(
                    context,
                    ref.read(doseActionsProvider).take(dose),
                  ),
          child: Text(
            l10n.takeAction,
            semanticsLabel: l10n.doseTakeLabel(name, time),
          ),
        );
    }
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    super.key,
  });

  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final size = context.metrics.touchTarget;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: foreground, semanticLabel: label),
    );
  }
}

/// Bottom sheet with the actions available for [dose]: take and skip while
/// it is open, undo once it is marked.
Future<void> showDoseActions(
  BuildContext context,
  WidgetRef ref,
  ScheduledDose dose,
) {
  final l10n = AppLocalizations.of(context);
  final actions = ref.read(doseActionsProvider);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      void run(Future<Object?> action) {
        Navigator.of(sheetContext).pop();
        runShowingErrors(context, action);
      }

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                doseTitle(l10n, dose),
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              subtitle: Text(doseDetail(sheetContext, dose)),
            ),
            if (dose.isOpen) ...[
              ListTile(
                key: const Key('dose-sheet-take'),
                leading: const Icon(Icons.check_circle_outline),
                title: Text(l10n.takeAction),
                onTap: () => run(actions.take(dose)),
              ),
              ListTile(
                key: const Key('dose-sheet-skip'),
                leading: const Icon(Icons.remove_circle_outline),
                title: Text(l10n.skipAction),
                onTap: () => run(actions.skip(dose)),
              ),
            ],
            if (dose.mark != null)
              ListTile(
                key: const Key('dose-sheet-undo'),
                leading: const Icon(Icons.undo),
                title: Text(l10n.undoAction),
                onTap: () => run(actions.undo(dose)),
              ),
          ],
        ),
      );
    },
  );
}
