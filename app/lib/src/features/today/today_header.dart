import 'dart:math' as math;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import '../common/clamped_text.dart';
import '../common/formatters.dart';
import '../common/gap.dart';
import '../common/pillpal_icon_button.dart';
import 'today_widgets.dart';

/// How many doses are taken of all (the ring and the counter line).
typedef TodayProgress = ({int done, int total});

/// The header of Today (B2-README section 8 and 9.3 to 9.4): the date, the
/// title (clamped at x1.5), the progress ring, and, until the text is large,
/// the settings and add buttons beside the date.
///
/// From the compact text scale on (x1.6) the actions move to their own line
/// under the title, right-aligned, and the ring gives way to the line
/// «Принято N из M». Either way `today-summary` is the progress: the ring, or
/// that line. A pushed day view of another profile has a back button instead
/// of the settings button.
class TodayHeader extends StatelessWidget {
  /// Creates the header.
  const TodayHeader({
    required this.date,
    required this.title,
    required this.pushed,
    required this.addRoute,
    required this.progress,
    super.key,
  });

  /// The day shown; null while it loads.
  final LocalDate? date;

  /// "Сегодня", or the name of the profile whose day it is.
  final String title;

  /// A pushed day view: a back button instead of the settings button.
  final bool pushed;

  /// Where "+" goes, or null for no "+".
  final String? addRoute;

  /// The progress of the day; null when there is nothing to count.
  final TodayProgress? progress;

  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.textScalerOf(context).scale(1) >= PillPalSizes.compactScale;
    final actions = _actions(context);
    final count = progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (pushed) _backButton(context),
            Expanded(child: _date(context)),
            if (!compact) ...actions,
          ],
        ),
        Row(
          children: [
            Expanded(
              child: ClampedText(
                title,
                key: const Key('today-title'),
                maxScale: PillPalSizes.titleMaxScale,
                style: Theme.of(context).textTheme.displaySmall,
              ),
            ),
            if (count != null && !compact) ...[
              const Gap.h(PillPalSpacing.md),
              ProgressRing(
                key: const Key('today-summary'),
                done: count.done,
                total: count.total,
              ),
            ],
          ],
        ),
        if (compact && actions.isNotEmpty)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Row(mainAxisSize: MainAxisSize.min, children: actions),
          ),
        if (compact && count != null)
          Padding(
            padding: const EdgeInsets.only(top: PillPalSpacing.xs),
            child: Text(
              AppLocalizations.of(context).todayProgress(
                count.done,
                count.total,
              ),
              key: const Key('today-summary'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
      ],
    );
  }

  Widget _date(BuildContext context) {
    final day = date;
    if (day == null) {
      return const SizedBox.shrink();
    }
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Text(
      formatLongDate(day, locale),
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: context.palette.inkMuted,
          ),
    );
  }

  Widget _backButton(BuildContext context) => PillPalIconButton(
        key: const Key('day-back'),
        icon: Icons.arrow_back,
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        onPressed: () => context.pop(),
      );

  /// Settings (the tab) and "+" (when the role allows it).
  List<Widget> _actions(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final route = addRoute;
    return [
      if (!pushed)
        PillPalIconButton(
          icon: Icons.settings_outlined,
          tooltip: l10n.settingsTitle,
          onPressed: () => context.push(AppRoutes.settings),
        ),
      if (route != null) ...[
        const Gap.h(PillPalSpacing.xs),
        _addButton(context, route),
      ],
    ];
  }

  /// The round «+» of the main colour (Q1 of docs/redesign-plan.md: the board
  /// shows none, the journeys and Settings need it).
  Widget _addButton(BuildContext context, String route) {
    final palette = context.palette;
    final side = math.max(PillPalSizes.roundCheck, context.metrics.touchTarget);
    return IconButton.filled(
      key: const Key('today-add'),
      tooltip: AppLocalizations.of(context).addMedication,
      constraints: BoxConstraints.tightFor(width: side, height: side),
      style: IconButton.styleFrom(
        backgroundColor: palette.action,
        foregroundColor: palette.onAction,
        shape: PillPalRadius.pill,
      ),
      icon: const Icon(Icons.add),
      onPressed: () => context.push(route),
    );
  }
}
