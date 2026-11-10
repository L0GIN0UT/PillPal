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
/// width «Принял» and a snooze. The only saturated block of the screen; in
/// the dark themes the soft green of the palette with a mint «Принял».
///
/// The name is clamped at x1.6 and breaks inside a word as a last resort. A
/// tap on the card outside the buttons (or a long press) opens the dose
/// actions, where it can be skipped. The buttons are `dose-take-<key>` and
/// `dose-snooze-<key>`; the caller keys the card itself.
///
/// With [senior] set (the senior Today screen) the same card has «Принял» 76
/// high with a 26 label, 64 high snooze and skip buttons, the spoken heading
/// «Сейчас пора принять» and the line "1 таблетка, 20:00". The senior screen
/// passes [onTake] (to confirm the mark with an undo), [onSkip] (a skip
/// button) and its own button keys.
class DoseHero extends ConsumerWidget {
  /// Creates the card.
  const DoseHero({
    required this.dose,
    required this.due,
    this.senior = false,
    this.onOpen,
    this.onTake,
    this.onSkip,
    this.snoozeKey,
    this.skipKey,
    super.key,
  });

  /// The dose.
  final ScheduledDose dose;

  /// Whether the dose is due («Сейчас») or comes later («Дальше»).
  final bool due;

  /// Whether to draw the card at senior sizes.
  final bool senior;

  /// Opens the actions of the dose; the card opens nothing when null.
  final VoidCallback? onOpen;

  /// Called by «Принял» instead of taking the dose directly (the senior
  /// screen shows a confirmation with an undo).
  final VoidCallback? onTake;

  /// Shows a skip button when set (the senior card; the normal one skips in
  /// the dose actions).
  final VoidCallback? onSkip;

  /// Key of the snooze button; `dose-snooze-<key>` when null.
  final Key? snoozeKey;

  /// Key of the skip button.
  final Key? skipKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final key = dose.occurrence.key;
    final busy = ref.watch(
      doseWritesInFlightProvider.select((keys) => keys.contains(key)),
    );
    final name = doseTitle(l10n, dose);
    final time = doseTime(dose);
    final onOpen = this.onOpen;
    return Material(
      color: palette.hero,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(borderRadius: PillPalRadius.hero),
      // Screen readers: the card itself opens more actions (skip is there).
      child: Semantics(
        hint: onOpen == null ? null : l10n.doseMoreActionsHint,
        child: InkWell(
          onTap: onOpen,
          onLongPress: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(PillPalSizes.heroPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _heading(context, time),
                const Gap.v(PillPalSpacing.md),
                ..._nameAndDetail(context, name, time),
                const Gap.v(PillPalSpacing.lg),
                _takeButton(context, ref, busy: busy, name: name, time: time),
                const Gap.v(PillPalSpacing.sm),
                _outlined(
                  context,
                  key: snoozeKey ?? ValueKey('dose-snooze-$key'),
                  label: l10n.snoozeAction(DoseTiming.snooze.inMinutes),
                  onPressed: busy ? null : () => snoozeDose(context, ref, dose),
                  semanticsLabel: null,
                ),
                if (onSkip != null) ...[
                  const Gap.v(PillPalSpacing.sm),
                  _outlined(
                    context,
                    key: skipKey,
                    label: l10n.skipAction,
                    onPressed: busy ? null : onSkip,
                    semanticsLabel: l10n.doseSkipLabel(name, time),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The bell and "Сейчас, 20:00" ("Сейчас пора принять" in senior mode,
  /// where the time is in the line under the name).
  Widget _heading(BuildContext context, String time) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final text = senior
        ? (due ? l10n.seniorTakeNow : l10n.seniorNext)
        : (due ? l10n.todayHeroDue(time) : l10n.todayHeroNext(time));
    return Row(
      children: [
        Icon(
          Icons.notifications_none,
          size: senior ? PillPalSizes.iconSenior : PillPalSizes.iconInline,
          color: palette.onHero,
        ),
        const Gap.h(PillPalSpacing.sm),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: palette.onHero),
          ),
        ),
      ],
    );
  }

  List<Widget> _nameAndDetail(BuildContext context, String name, String time) {
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final detail = doseDetail(context, dose);
    // Senior mode has no time in the heading: "1 таблетка, 20:00".
    final line = !senior ? detail : (detail.isEmpty ? time : '$detail, $time');
    return [
      ClampedText(
        name,
        maxScale: PillPalSizes.heroNameMaxScale,
        style: textTheme.headlineMedium?.copyWith(color: palette.onHero),
      ),
      if (line.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: PillPalSpacing.xs),
          child: Text(
            line,
            style: textTheme.bodyLarge?.copyWith(color: palette.onHero),
          ),
        ),
    ];
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
    final textTheme = Theme.of(context).textTheme;
    final height = senior
        ? PillPalSizes.seniorTakeHeight
        : math.max(PillPalSizes.stackedButtonMin, context.metrics.touchTarget);
    return FilledButton.icon(
      key: ValueKey('dose-take-${dose.occurrence.key}'),
      style: FilledButton.styleFrom(
        backgroundColor: palette.heroAction,
        foregroundColor: palette.onHeroAction,
        minimumSize: Size.fromHeight(height),
        textStyle: senior ? textTheme.heroTakeSenior : textTheme.heroTake,
      ),
      onPressed: busy
          ? null
          : onTake ??
              () => runShowingErrors(
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

  /// An outline button on the card (snooze, skip): `onHero` at 55 %.
  Widget _outlined(
    BuildContext context, {
    required Key? key,
    required String label,
    required VoidCallback? onPressed,
    required String? semanticsLabel,
  }) {
    final palette = context.palette;
    return OutlinedButton(
      key: key,
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
      onPressed: onPressed,
      child: Text(
        label,
        textAlign: TextAlign.center,
        semanticsLabel: semanticsLabel,
      ),
    );
  }
}
