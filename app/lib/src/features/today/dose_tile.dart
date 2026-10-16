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
      ? dose.medication.name
      : '${dose.medication.name} $strength';
}

/// Wall-clock time of [dose] on the device (`HH:MM`).
String doseTime(ScheduledDose dose, String deviceTz) => dose.zone == deviceTz
    ? dose.occurrence.localTime
    : wallClockOf(dose.dueAt, deviceTz).hhmm;

/// "1 таблетка · после еды".
String doseDetail(BuildContext context, ScheduledDose dose) {
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
class DoseTile extends ConsumerWidget {
  /// Creates the tile.
  const DoseTile({required this.dose, super.key});

  /// The dose.
  final ScheduledDose dose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final tz = ref.watch(deviceTimeZoneProvider);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(PillPalSizes.cardRadius),
        onTap: () => showDoseActions(context, ref, dose),
        onLongPress: () => showDoseActions(context, ref, dose),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          child: Row(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 52),
                child: Text(
                  doseTime(dose, tz),
                  textAlign: TextAlign.center,
                  style: textTheme.titleLarge,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(medicationTitle(dose), style: textTheme.titleMedium),
                    Text(doseDetail(context, dose), style: textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              DoseStatusAction(dose: dose),
            ],
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
    final name = medicationTitle(dose);
    final time = doseTime(dose, ref.watch(deviceTimeZoneProvider));
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
                medicationTitle(dose),
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
