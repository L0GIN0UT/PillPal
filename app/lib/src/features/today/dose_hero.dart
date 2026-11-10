import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import '../common/clamped_text.dart';
import '../common/error_snack_bar.dart';
import '../common/gap.dart';
import '../doses/dose_providers.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';
import 'dose_tile.dart';

/// Snoozes [dose] and says so; the same path as the senior card.
void snoozeDose(BuildContext context, WidgetRef ref, ScheduledDose dose) {
  runShowingErrors(context, ref.read(doseActionsProvider).snooze(dose));
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(AppLocalizations.of(context).snoozedNote)),
  );
}

/// The pine «Сейчас» card (B2-README `hero`): when and what to take, a full
/// width «Принял» and a snooze. The only saturated block of the screen.
///
/// The name is clamped at x1.6 and breaks inside a word as a last resort. A
/// tap on the card outside the buttons (or a long press) opens the dose
/// actions, where it can be skipped. The buttons are `dose-take-<key>` and
/// `dose-snooze-<key>`; the caller keys the card itself.
class DoseHero extends ConsumerWidget {
  /// Creates the card.
  const DoseHero({
    required this.dose,
    required this.due,
    required this.onOpen,
    super.key,
  });

  /// The dose.
  final ScheduledDose dose;

  /// Whether the dose is due («Сейчас») or comes later («Дальше»).
  final bool due;

  /// Opens the actions of the dose.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final key = dose.occurrence.key;
    final busy = ref.watch(
      doseWritesInFlightProvider.select((keys) => keys.contains(key)),
    );
    final name = doseTitle(l10n, dose);
    final time = doseTime(dose);
    final detail = doseDetail(context, dose);
    return Material(
      color: palette.hero,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(borderRadius: PillPalRadius.hero),
      // Screen readers: the card itself opens more actions (skip is there).
      child: Semantics(
        hint: l10n.doseMoreActionsHint,
        child: InkWell(
          onTap: onOpen,
          onLongPress: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(PillPalSizes.heroPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.notifications_none,
                      size: PillPalSizes.iconInline,
                      color: palette.onHero,
                    ),
                    const Gap.h(PillPalSpacing.sm),
                    Expanded(
                      child: Text(
                        due
                            ? l10n.todayHeroDue(time)
                            : l10n.todayHeroNext(time),
                        style: textTheme.titleSmall
                            ?.copyWith(color: palette.onHero),
                      ),
                    ),
                  ],
                ),
                const Gap.v(PillPalSpacing.md),
                ClampedText(
                  name,
                  maxScale: PillPalSizes.heroNameMaxScale,
                  style: textTheme.headlineMedium?.copyWith(
                    color: palette.onHero,
                  ),
                ),
                if (detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: PillPalSpacing.xs),
                    child: Text(
                      detail,
                      style:
                          textTheme.bodyLarge?.copyWith(color: palette.onHero),
                    ),
                  ),
                const Gap.v(PillPalSpacing.lg),
                _takeButton(context, ref, busy: busy, name: name, time: time),
                const Gap.v(PillPalSpacing.sm),
                _snoozeButton(context, ref, busy: busy),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _takeButton(
    BuildContext context,
    WidgetRef ref, {
    required bool busy,
    required String name,
    required String time,
  }) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final height = math.max(
      PillPalSizes.stackedButtonMin,
      context.metrics.touchTarget,
    );
    return FilledButton.icon(
      key: ValueKey('dose-take-${dose.occurrence.key}'),
      style: FilledButton.styleFrom(
        backgroundColor: palette.heroAction,
        foregroundColor: palette.onHeroAction,
        minimumSize: Size.fromHeight(height),
        textStyle: Theme.of(context).textTheme.heroTake,
      ),
      onPressed: busy
          ? null
          : () => runShowingErrors(
                context,
                ref.read(doseActionsProvider).take(dose),
              ),
      icon: const Icon(Icons.check_rounded),
      label: Text(
        l10n.takeAction,
        semanticsLabel: l10n.doseTakeLabel(name, time),
      ),
    );
  }

  Widget _snoozeButton(
    BuildContext context,
    WidgetRef ref, {
    required bool busy,
  }) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    return OutlinedButton(
      key: ValueKey('dose-snooze-${dose.occurrence.key}'),
      style: OutlinedButton.styleFrom(
        // The secondary button is filled with `surface` by the theme; here it
        // is an outline on the pine card.
        backgroundColor: Colors.transparent,
        foregroundColor: palette.onHero,
        side: BorderSide(
          color: palette.onHero.withValues(
            alpha: PillPalSizes.heroOutlineOpacity,
          ),
          width: PillPalSizes.fieldBorder,
        ),
      ),
      onPressed: busy ? null : () => snoozeDose(context, ref, dose),
      child: Text(
        l10n.snoozeAction(DoseTiming.snooze.inMinutes),
        textAlign: TextAlign.center,
      ),
    );
  }
}
