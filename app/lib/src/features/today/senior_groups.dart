import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/action_sheet.dart';
import '../common/gap.dart';
import '../common/pillpal_card.dart';
import '../common/sheet_scaffold.dart';
import '../common/status_disc.dart';
import '../common/status_kind.dart';
import '../common/text_fit.dart';
import '../doses/day_part.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';
import 'dose_rows.dart';
import 'dose_tile.dart';

/// The one status of the doses at a time: missed first, then waiting while
/// any dose is pending, else taken (any taken) or skipped.
StatusKind groupStatusKind(List<ScheduledDose> doses) {
  assert(doses.isNotEmpty, 'a group has at least one dose');
  if (doses.any((d) => d.status == DoseStatus.missed)) {
    return StatusKind.missed;
  }
  if (doses.any((d) => d.status == DoseStatus.pending)) {
    return StatusKind.pending;
  }
  return doses.any((d) => d.status == DoseStatus.taken)
      ? StatusKind.taken
      : StatusKind.skipped;
}

/// The doses of one time as a card (B-TodaySenior): a 52 status disc (an
/// icon, solid in senior mode), the time, the names and the status word. A
/// tap opens take/skip/undo of the dose, or a list to pick from when several
/// doses share the time.
///
/// Keys: the row is `senior-group-<time>`, the names
/// `senior-group-names-<time>` and the status word
/// `senior-group-status-<time>`.
class SeniorTimeGroup extends ConsumerWidget {
  /// Creates the group.
  const SeniorTimeGroup({required this.time, required this.doses, super.key});

  /// `HH:MM` of the doses.
  final String time;

  /// The doses at [time]; never empty.
  final List<ScheduledDose> doses;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final kind = groupStatusKind(doses);
    final word = statusWord(l10n, kind);
    final names = doses.map((d) => doseTitle(l10n, d)).join(', ');
    final title = l10n.seniorGroupTitle(
      dayPartLabel(l10n, dayPartOf(time)),
      time,
    );
    final namesStyle = textTheme.rowTitle.copyWith(color: palette.inkMuted);
    void open() {
      if (doses.length == 1) {
        unawaited(showDoseActions(context, ref, doses.single));
      } else {
        unawaited(_showGroup(context, ref));
      }
    }

    return PillPalCard(
      padding: EdgeInsets.zero,
      child: Semantics(
        button: true,
        label: l10n.doseStatusLabel(names, title, word),
        excludeSemantics: true,
        onTap: open,
        child: DoseRowFrame(
          key: ValueKey('senior-group-$time'),
          onOpen: open,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final heading = Text(title, style: textTheme.titleLarge);
              final lines = [
                Text(
                  names,
                  key: ValueKey('senior-group-names-$time'),
                  style: namesStyle,
                ),
                Text(
                  word,
                  key: ValueKey('senior-group-status-$time'),
                  style: textTheme.titleMedium,
                ),
              ];
              final disc = context.metrics.isSenior
                  ? PillPalSizes.statusDiscSenior
                  : PillPalSizes.statusDisc;
              final beside = wordsFit(
                context,
                constraints.maxWidth - disc - PillPalSpacing.lg,
                [
                  (title, textTheme.titleLarge),
                  (names, namesStyle),
                  (word, textTheme.titleMedium),
                ],
              );
              if (!beside) {
                // The names under the disc, the whole width: beside it a
                // long name would break inside a word (a narrow screen).
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        StatusDisc(kind),
                        const Gap.h(PillPalSpacing.lg),
                        Expanded(child: heading),
                      ],
                    ),
                    const Gap.v(PillPalSpacing.xs),
                    ...lines,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StatusDisc(kind),
                  const Gap.h(PillPalSpacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [heading, ...lines],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Several doses at one time: pick one, then its actions.
  Future<void> _showGroup(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return showPillPalSheet<void>(
      context,
      (sheetContext) => ActionSheet(
        items: [
          for (final dose in doses)
            ActionSheetItem(
              key: ValueKey('senior-group-dose-${dose.occurrence.key}'),
              title: doseTitle(l10n, dose),
              subtitle: statusWord(l10n, StatusKind.fromDose(dose.status)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(showDoseActions(context, ref, dose));
              },
            ),
        ],
      ),
    );
  }
}
