import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import '../common/action_sheet.dart';
import '../common/error_snack_bar.dart';
import '../common/formatters.dart';
import '../common/gap.dart';
import '../common/local_time.dart';
import '../common/sheet_scaffold.dart';
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
  const DoseTile({required this.dose, required this.canMark, super.key});

  /// The dose.
  final ScheduledDose dose;

  /// Whether the user may mark this dose (no default: a caller that does
  /// not know the role must not offer the buttons).
  final bool canMark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status =
        canMark ? DoseStatusAction(dose: dose) : ReadOnlyDoseStatus(dose: dose);
    return Card(
      child: InkWell(
        borderRadius: PillPalRadius.card,
        onTap: canMark ? () => showDoseActions(context, ref, dose) : null,
        onLongPress: canMark ? () => showDoseActions(context, ref, dose) : null,
        child: Padding(
          padding: PillPalSpacing.card,
          // The layout follows the width: the status sits beside the text
          // while it fits next to a readable summary, else under it.
          child: LayoutBuilder(
            builder: (context, constraints) {
              // The text keeps its minimum width at the current text scale.
              final summaryMin = MediaQuery.textScalerOf(context)
                  .scale(PillPalSizes.doseSummaryMinWidth);
              final beside =
                  _statusWidth(context) + PillPalSpacing.sm + summaryMin <=
                      constraints.maxWidth;
              if (beside) {
                return Row(
                  children: [
                    Expanded(child: _summary(context, stacked: false)),
                    const Gap.h(PillPalSpacing.sm),
                    status,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _summary(context, stacked: true),
                  const Gap.v(PillPalSpacing.sm),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: status,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// The width the status takes at the current text scale: a badge is a
  /// touch target; a button or a word is its label plus padding and outline,
  /// never below the target.
  double _statusWidth(BuildContext context) {
    final target = context.metrics.touchTarget;
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final String label;
    TextStyle? style;
    switch (dose.status) {
      case DoseStatus.taken:
      case DoseStatus.skipped:
        return target;
      case DoseStatus.missed:
        label = l10n.statusMissed;
        style = canMark
            ? theme.filledButtonTheme.style?.textStyle?.resolve({})
            : theme.textTheme.labelMedium;
      case DoseStatus.pending:
        label = canMark ? l10n.takeAction : l10n.statusPending;
        style = canMark
            ? theme.filledButtonTheme.style?.textStyle?.resolve({})
            : theme.textTheme.labelMedium;
    }
    final painter = TextPainter(
      text: TextSpan(text: label, style: style ?? theme.textTheme.labelLarge),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width =
        painter.width + 2 * PillPalSpacing.md + 2 * PillPalSizes.outline;
    painter.dispose();
    return math.max(width, target);
  }

  /// The time, the name and the dose; [stacked] puts the time above the
  /// text, for large text scales.
  Widget _summary(BuildContext context, {required bool stacked}) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final detail = doseDetail(context, dose);
    final time = ConstrainedBox(
      constraints: const BoxConstraints(minWidth: PillPalSizes.doseTimeWidth),
      child: Text(
        doseTime(dose),
        textAlign: stacked ? TextAlign.start : TextAlign.center,
        style: textTheme.titleLarge,
      ),
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(doseTitle(l10n, dose), style: textTheme.titleMedium),
        if (detail.isNotEmpty) Text(detail, style: textTheme.bodySmall),
      ],
    );
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [time, text],
      );
    }
    return Row(
      children: [
        time,
        const Gap.h(PillPalSpacing.md),
        Expanded(child: text),
      ],
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
        padding: const EdgeInsets.symmetric(horizontal: PillPalSpacing.md),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: PillPalRadius.chip,
          border: Border.all(color: color, width: PillPalSizes.outline),
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
            padding: const EdgeInsets.symmetric(horizontal: PillPalSpacing.md),
            foregroundColor: palette.missed,
            side: BorderSide(
              color: palette.missed,
              width: PillPalSizes.outline,
            ),
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
            padding: const EdgeInsets.symmetric(horizontal: PillPalSpacing.md),
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
        borderRadius: PillPalRadius.chip,
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
  return showPillPalSheet<void>(context, (sheetContext) {
    void run(Future<Object?> action) {
      Navigator.of(sheetContext).pop();
      runShowingErrors(context, action);
    }

    final detail = doseDetail(sheetContext, dose);
    return ActionSheet(
      title: doseTitle(l10n, dose),
      subtitle: detail.isEmpty ? null : detail,
      items: [
        if (dose.isOpen) ...[
          ActionSheetItem(
            key: const Key('dose-sheet-take'),
            icon: Icons.check_circle_outline,
            title: l10n.takeAction,
            onTap: () => run(actions.take(dose)),
          ),
          ActionSheetItem(
            key: const Key('dose-sheet-skip'),
            icon: Icons.remove_circle_outline,
            title: l10n.skipAction,
            onTap: () => run(actions.skip(dose)),
          ),
        ],
        if (dose.mark != null)
          ActionSheetItem(
            key: const Key('dose-sheet-undo'),
            icon: Icons.undo,
            title: l10n.undoAction,
            onTap: () => run(actions.undo(dose)),
          ),
      ],
    );
  });
}
