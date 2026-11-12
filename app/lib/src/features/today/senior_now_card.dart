import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/repositories/dose_events_repository.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../../theme/text_theme.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';
import '../common/pillpal_card.dart';
import '../common/status_disc.dart';
import '../common/status_kind.dart';
import '../doses/scheduled_doses.dart';
import 'dose_hero.dart';
import 'dose_tile.dart';

/// A mark just made on the "now" card, shown with an undo before the card
/// moves on to the next dose.
typedef SeniorConfirmation = ({
  ScheduledDose dose,
  DoseEventType type,
  String eventId,
});

/// The dose to take now in senior mode (B-TodaySenior): the same pine card as
/// the normal Today (`DoseHero`) at senior sizes, with «Принял» 76 high,
/// remind-later and skip 64 high. The buttons keep their senior keys
/// (`dose-take-<key>`, `senior-snooze`, `senior-skip`); the card is
/// `senior-now`.
class SeniorNowCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return DoseHero(
      key: const Key('senior-now'),
      dose: dose,
      due: due,
      senior: true,
      onTake: onTake,
      onSkip: onSkip,
      snoozeKey: const Key('senior-snooze'),
      skipKey: const Key('senior-skip'),
    );
  }
}

/// "Taken ✓ · Undo" for a moment after a mark on the "now" card: a status
/// disc, the word, what was marked and a 64 high undo.
class SeniorConfirmationCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final dose = confirmation.dose;
    final taken = confirmation.type == DoseEventType.taken;
    final name = doseTitle(l10n, dose);
    final time = doseTime(dose);
    return Semantics(
      liveRegion: true,
      container: true,
      child: PillPalCard(
        key: const Key('senior-confirmation'),
        padding: const EdgeInsets.all(PillPalSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                StatusDisc(taken ? StatusKind.taken : StatusKind.skipped),
                const Gap.h(PillPalSpacing.lg),
                Expanded(
                  child: Text(
                    taken ? l10n.seniorConfirmTaken : l10n.statusSkipped,
                    style: textTheme.headlineSmall,
                  ),
                ),
              ],
            ),
            const Gap.v(PillPalSpacing.sm),
            Text(
              '$name · $time',
              style: textTheme.rowTitle.copyWith(
                color: context.palette.inkMuted,
              ),
            ),
            const Gap.v(PillPalSpacing.lg),
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

/// Everything for today is marked: the calm banner of the normal Today.
class SeniorAllDoneCard extends StatelessWidget {
  /// Creates the card.
  const SeniorAllDoneCard({super.key});

  @override
  Widget build(BuildContext context) {
    return PillPalBanner(
      key: const Key('today-all-taken'),
      icon: Icons.check_circle_outline,
      title: AppLocalizations.of(context).todayAllTaken,
    );
  }
}
