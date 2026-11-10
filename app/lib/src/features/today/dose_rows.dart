import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/error_snack_bar.dart';
import '../common/gap.dart';
import '../common/round_check_button.dart';
import '../common/status_disc.dart';
import '../common/status_kind.dart';
import '../common/status_pill.dart';
import '../doses/dose_providers.dart';
import '../doses/scheduled_doses.dart';
import 'dose_tile.dart';

/// The row of a dose in «Дальше» (B2-README `listRow` with the `roundCheck`):
/// the name, "22:00, 2 таблетки", and the round check that takes the dose at
/// once (`dose-take-<key>`). A relative who may not mark sees a status pill
/// instead (`dose-status-<key>`).
///
/// The check sits at the top of the row when the text wraps over several
/// lines (section 9.8). A tap on the row opens the dose actions.
class UpcomingDoseRow extends ConsumerWidget {
  /// Creates the row.
  const UpcomingDoseRow({
    required this.dose,
    required this.canMark,
    required this.onOpen,
    super.key,
  });

  /// The dose.
  final ScheduledDose dose;

  /// Whether the user may mark it.
  final bool canMark;

  /// Opens the actions of the dose; null for a row that opens nothing.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final key = dose.occurrence.key;
    final busy = ref.watch(
      doseWritesInFlightProvider.select((keys) => keys.contains(key)),
    );
    final name = doseTitle(l10n, dose);
    final time = doseTime(dose);
    final trailing = canMark
        ? RoundCheckButton(
            key: ValueKey('dose-take-$key'),
            label: l10n.doseTakeLabel(name, time),
            onPressed: () {
              if (!busy) {
                runShowingErrors(
                  context,
                  ref.read(doseActionsProvider).take(dose),
                );
              }
            },
          )
        : StatusPill(
            StatusKind.pending,
            key: ValueKey('dose-status-$key'),
          );
    final text = DoseRowText(
      title: name,
      line: _line(context),
      minHeight: _trailingHeight(context),
    );
    // A pill is wide: from the compact scale on it drops under the text
    // instead of squeezing the name (section 9.8; the check stays beside).
    final compact =
        MediaQuery.textScalerOf(context).scale(1) >= PillPalSizes.compactScale;
    if (!canMark && compact) {
      return DoseRowFrame(
        onOpen: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            text,
            const Gap.v(PillPalSpacing.xs),
            trailing,
          ],
        ),
      );
    }
    return DoseRowFrame(
      onOpen: onOpen,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: text),
          const Gap.h(PillPalSpacing.md),
          trailing,
        ],
      ),
    );
  }

  /// "22:00, 2 таблетки"; the time alone when there is no dose to show.
  String _line(BuildContext context) {
    final detail = doseDetail(context, dose);
    final time = doseTime(dose);
    return detail.isEmpty ? time : '$time, $detail';
  }

  double _trailingHeight(BuildContext context) =>
      math.max(PillPalSizes.roundCheck, context.metrics.touchTarget);
}

/// The row of a dose in «Уже было»: a status disc, the name and the status
/// line "08:00, принято". The line is the status word, so the status is an
/// icon plus a word; its colours are the soft pair of the status, and a
/// missed dose is calm iris, never red.
///
/// The line carries `dose-taken-<key>`, `dose-skipped-<key>` or
/// `dose-missed-<key>`; for a relative who may not mark it is
/// `dose-status-<key>`. A tap on the row opens take, skip or undo; a missed
/// row also has the round check (`dose-take-<key>`) to take it at once.
class PastDoseRow extends ConsumerWidget {
  /// Creates the row.
  const PastDoseRow({
    required this.dose,
    required this.canMark,
    required this.onOpen,
    super.key,
  });

  /// The dose.
  final ScheduledDose dose;

  /// Whether the user may mark it.
  final bool canMark;

  /// Opens the actions of the dose; null for a row that opens nothing.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final kind = StatusKind.fromDose(dose.status);
    final word = statusWord(l10n, kind).toLowerCase();
    final color = switch (kind) {
      StatusKind.taken => palette.onTakenSoft,
      StatusKind.missed => palette.onMissedSoft,
      _ => palette.inkMuted,
    };
    final disc = context.metrics.isSenior
        ? PillPalSizes.statusDiscSenior
        : PillPalSizes.statusDisc;
    return DoseRowFrame(
      onOpen: onOpen,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusDisc(kind),
          const Gap.h(PillPalSpacing.md),
          Expanded(
            child: DoseRowText(
              title: doseTitle(l10n, dose),
              line: '${doseTime(dose)}, $word',
              lineKey: _statusKey(kind),
              lineColor: color,
              minHeight: disc,
            ),
          ),
          // A missed dose can still be taken: one tap, like a later dose.
          if (canMark && kind == StatusKind.missed) ...[
            const Gap.h(PillPalSpacing.md),
            _lateTake(context, ref),
          ],
        ],
      ),
    );
  }

  Widget _lateTake(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final key = dose.occurrence.key;
    final busy = ref.watch(
      doseWritesInFlightProvider.select((keys) => keys.contains(key)),
    );
    return RoundCheckButton(
      key: ValueKey('dose-take-$key'),
      label: l10n.doseTakeLabel(doseTitle(l10n, dose), doseTime(dose)),
      onPressed: () {
        if (!busy) {
          runShowingErrors(context, ref.read(doseActionsProvider).take(dose));
        }
      },
    );
  }

  /// `dose-status-<key>` for a read-only row, else the key of the status
  /// (spelled out, so the journey-key test finds each prefix in `lib/`).
  Key _statusKey(StatusKind kind) {
    final key = dose.occurrence.key;
    if (!canMark) {
      return ValueKey('dose-status-$key');
    }
    return switch (kind) {
      StatusKind.taken => ValueKey('dose-taken-$key'),
      StatusKind.skipped => ValueKey('dose-skipped-$key'),
      StatusKind.missed => ValueKey('dose-missed-$key'),
      _ => ValueKey('dose-status-$key'),
    };
  }
}

/// The tappable frame of a dose row: at least as high as a list row (76 in
/// senior mode), 16 at the sides and 12 above and below.
class DoseRowFrame extends StatelessWidget {
  /// Creates the frame.
  const DoseRowFrame({required this.child, required this.onOpen, super.key});

  /// The row content.
  final Widget child;

  /// Called on tap and long press; null makes the row plain.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final minHeight = context.metrics.isSenior
        ? PillPalSizes.listRowMinSenior
        : PillPalSizes.listRowMin;
    return InkWell(
      onTap: onOpen,
      onLongPress: onOpen,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        // heightFactor: as high as the content or the minimum, not as high
        // as the space the parent offers.
        child: Center(
          heightFactor: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PillPalSpacing.lg,
              vertical: PillPalSpacing.md,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The name and the muted line under it. Centred on [minHeight] (the height
/// of the element beside it) while it is shorter, so a one-line row is level
/// with its check or disc; a taller text starts at the top, and the element
/// stays at the top too (section 9.8).
class DoseRowText extends StatelessWidget {
  /// Creates the text block.
  const DoseRowText({
    required this.title,
    required this.line,
    required this.minHeight,
    this.lineKey,
    this.lineColor,
    super.key,
  });

  /// The name of the medication.
  final String title;

  /// The line under the name.
  final String line;

  /// Height of the element beside the text.
  final double minHeight;

  /// Key of the line, for tests and journeys.
  final Key? lineKey;

  /// Colour of the line; muted when null.
  final Color? lineColor;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: textTheme.rowTitle),
          Text(
            line,
            key: lineKey,
            style: textTheme.bodyMedium?.copyWith(
              color: lineColor ?? palette.inkMuted,
            ),
          ),
        ],
      ),
    );
  }
}
