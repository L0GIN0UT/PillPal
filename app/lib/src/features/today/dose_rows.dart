import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/compact_rows.dart';
import '../common/compact_text.dart';
import '../common/error_snack_bar.dart';
import '../common/round_check_button.dart';
import '../common/status_disc.dart';
import '../common/status_kind.dart';
import '../common/status_pill.dart';
import '../doses/dose_providers.dart';
import '../doses/scheduled_doses.dart';
import 'dose_row_layout.dart';
import 'dose_tile.dart';

/// The round check that takes [dose] at once (`dose-take-<key>`).
Widget _takeButton(BuildContext context, WidgetRef ref, ScheduledDose dose) {
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

/// The row of a dose in «Дальше» (B2-README `listRow` with the `roundCheck`):
/// the name, "22:00, 2 таблетки", and the round check that takes the dose at
/// once (`dose-take-<key>`). A relative who may not mark sees a status pill
/// instead (`dose-status-<key>`).
///
/// The check sits at the top of the row when the text wraps over several
/// lines (section 9.8). A pill drops under the text from the compact scale
/// on; the check or the pill also drops on a screen too narrow for a word of
/// the name beside it, for every row of the card at once. A tap on the row
/// opens the dose actions.
class UpcomingDoseRow extends ConsumerWidget implements NarrowAware {
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

  /// "22:00, 2 таблетки"; the time alone when there is no dose to show.
  String _line(BuildContext context) {
    final detail = doseDetail(context, dose);
    final time = doseTime(dose);
    return detail.isEmpty ? time : '$time, $detail';
  }

  /// The width inside the frame for the name and the check or the pill on
  /// one line: the pill is measured, not assumed.
  double _innerFullWidth(BuildContext context) {
    final trailing = canMark
        ? doseCheckSide(context)
        : StatusPill.widthOf(context, StatusKind.pending);
    final title = doseTitle(AppLocalizations.of(context), dose);
    return doseRowWord(context, title, _line(context)) +
        PillPalSpacing.md +
        trailing;
  }

  @override
  double fullLayoutWidth(BuildContext context) =>
      2 * PillPalSpacing.lg + _innerFullWidth(context);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = dose.occurrence.key;
    final trailing = canMark
        ? _takeButton(context, ref, dose)
        : StatusPill(StatusKind.pending, key: ValueKey('dose-status-$key'));
    return DoseRowFrame(
      onOpen: onOpen,
      child: DoseRowLayout(
        text: DoseRowText(
          title: doseTitle(AppLocalizations.of(context), dose),
          line: _line(context),
          minHeight: doseCheckSide(context),
        ),
        trailing: trailing,
        innerFullWidth: _innerFullWidth(context),
        // A pill is wide: from the compact scale on it drops under the text
        // (section 9.8; the check stays beside).
        below: !canMark && isCompactText(context),
      ),
    );
  }
}

/// The row of a dose in «Уже было»: a status disc, the name and the status
/// line "08:00, принято". The line is the status word, so the status is an
/// icon plus a word; its colours are the soft pair of the status, and a
/// missed dose is calm iris, never red.
///
/// The line carries `dose-taken-<key>`, `dose-skipped-<key>` or
/// `dose-missed-<key>`; for a relative who may not mark it is
/// `dose-status-<key>`. A tap on the row opens take, skip or undo; a missed
/// row also has the round check (`dose-take-<key>`) to take it at once. On a
/// screen too narrow for a word of the name between them, the disc and the
/// check go together under the name, in every row of the card.
class PastDoseRow extends ConsumerWidget implements NarrowAware {
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

  StatusKind get _kind => StatusKind.fromDose(dose.status);

  /// A missed dose can still be taken: one tap, like a later dose.
  bool get _lateTake => canMark && _kind == StatusKind.missed;

  String _line(AppLocalizations l10n) =>
      '${doseTime(dose)}, ${statusWord(l10n, _kind).toLowerCase()}';

  double _disc(BuildContext context) => context.metrics.isSenior
      ? PillPalSizes.statusDiscSenior
      : PillPalSizes.statusDisc;

  /// The width inside the frame for the disc, the name and the check on one
  /// line.
  double _innerFullWidth(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _disc(context) +
        PillPalSpacing.md +
        doseRowWord(context, doseTitle(l10n, dose), _line(l10n)) +
        (_lateTake ? PillPalSpacing.md + doseCheckSide(context) : 0.0);
  }

  @override
  double fullLayoutWidth(BuildContext context) =>
      2 * PillPalSpacing.lg + _innerFullWidth(context);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final color = switch (_kind) {
      StatusKind.taken => palette.onTakenSoft,
      StatusKind.missed => palette.onMissedSoft,
      _ => palette.inkMuted,
    };
    return DoseRowFrame(
      onOpen: onOpen,
      child: DoseRowLayout(
        leading: StatusDisc(_kind),
        text: DoseRowText(
          title: doseTitle(l10n, dose),
          line: _line(l10n),
          lineKey: _statusKey(_kind),
          lineColor: color,
          minHeight: _disc(context),
        ),
        trailing: _lateTake ? _takeButton(context, ref, dose) : null,
        innerFullWidth: _innerFullWidth(context),
      ),
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
