import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/action_sheet.dart';
import '../common/gap.dart';
import '../common/pillpal_card.dart';
import '../common/sheet_scaffold.dart';
import '../common/status_disc.dart';
import '../common/status_kind.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';
import 'dose_rows.dart';
import 'dose_tile.dart';

/// The one status of the doses at a time: all taken, any missed, all
/// skipped, or still waiting.
StatusKind groupStatusKind(List<ScheduledDose> doses) {
  if (doses.every((d) => d.status == DoseStatus.taken)) {
    return StatusKind.taken;
  }
  if (doses.any((d) => d.status == DoseStatus.missed)) {
    return StatusKind.missed;
  }
  if (doses.every((d) => d.status == DoseStatus.skipped)) {
    return StatusKind.skipped;
  }
  return StatusKind.pending;
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
    final names = doses.map(medicationTitle).join(', ');
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
        label: l10n.doseStatusLabel(names, time, word),
        excludeSemantics: true,
        onTap: open,
        child: DoseRowFrame(
          key: ValueKey('senior-group-$time'),
          onOpen: open,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StatusDisc(kind),
              const Gap.h(PillPalSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(time, style: textTheme.titleLarge),
                    Text(
                      names,
                      key: ValueKey('senior-group-names-$time'),
                      style: textTheme.bodyLarge?.copyWith(
                        color: palette.inkMuted,
                      ),
                    ),
                    Text(
                      word,
                      key: ValueKey('senior-group-status-$time'),
                      style: textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
            ],
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
              title: medicationTitle(dose),
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
