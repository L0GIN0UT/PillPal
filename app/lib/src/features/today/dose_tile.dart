import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../common/action_sheet.dart';
import '../common/compact_rows.dart';
import '../common/error_snack_bar.dart';
import '../common/formatters.dart';
import '../common/local_time.dart';
import '../common/sheet_scaffold.dart';
import '../doses/dose_providers.dart';
import '../doses/scheduled_doses.dart';
import 'dose_hero.dart';
import 'dose_rows.dart';

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

/// How a [DoseTile] looks (B2-README section 8, Today).
enum DoseTileLayout {
  /// The pine «Сейчас» card: the dose to take now, with «Принял» and snooze.
  hero,

  /// A row of «Дальше»: time and dose, the round check to take it at once.
  upcoming,

  /// A row of «Уже было»: a status disc and the status line.
  past,
}

/// One scheduled dose on Today, in one of three [DoseTileLayout]s. The
/// screen gives every dose exactly one tile, keyed by its occurrence key.
///
/// With [canMark] false (a relative's day view: viewers and editors never
/// mark, D3) the tile only shows the status, never a button, and opens
/// nothing; there is no hero then.
class DoseTile extends ConsumerWidget implements NarrowAware {
  /// Creates the tile.
  const DoseTile({
    required this.dose,
    required this.canMark,
    this.layout = DoseTileLayout.upcoming,
    this.due = true,
    super.key,
  }) : assert(
          canMark || layout != DoseTileLayout.hero,
          'only a dose the user may mark can be the hero',
        );

  /// The dose.
  final ScheduledDose dose;

  /// Whether the user may mark this dose (no default: a caller that does
  /// not know the role must not offer the buttons).
  final bool canMark;

  /// The look of the tile.
  final DoseTileLayout layout;

  /// For the hero: whether the dose is due already («Сейчас») or comes later
  /// («Дальше»).
  final bool due;

  /// What the row of [layout] needs to keep its parts on one line; a hero
  /// card has no narrow layout.
  @override
  double? fullLayoutWidth(BuildContext context) => switch (layout) {
        DoseTileLayout.hero => null,
        DoseTileLayout.upcoming =>
          UpcomingDoseRow(dose: dose, canMark: canMark, onOpen: null)
              .fullLayoutWidth(context),
        DoseTileLayout.past =>
          PastDoseRow(dose: dose, canMark: canMark, onOpen: null)
              .fullLayoutWidth(context),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void open() => showDoseActions(context, ref, dose);
    switch (layout) {
      case DoseTileLayout.hero:
        return DoseHero(dose: dose, due: due, onOpen: open);
      case DoseTileLayout.upcoming:
        return UpcomingDoseRow(
          dose: dose,
          canMark: canMark,
          onOpen: canMark ? open : null,
        );
      case DoseTileLayout.past:
        return PastDoseRow(
          dose: dose,
          canMark: canMark,
          onOpen: canMark ? open : null,
        );
    }
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
