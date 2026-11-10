import 'package:flutter/material.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/formatters.dart';
import '../common/gap.dart';
import '../common/pillpal_card.dart';
import '../common/pillpal_icon_button.dart';
import 'calendar_cell.dart';
import 'history_model.dart';

export 'calendar_cell.dart';

/// Month grid, Monday first, with legend, in a card; own widget (no package).
/// [summary] (the adherence numerals) sits between the month and the grid.
class MonthCalendar extends StatelessWidget {
  /// Creates the calendar.
  const MonthCalendar({
    required this.history,
    required this.selected,
    required this.onSelect,
    required this.onPrevious,
    required this.onNext,
    this.summary,
    super.key,
  });

  /// The month.
  final MonthHistory history;

  /// Selected day.
  final LocalDate? selected;

  /// Day tap.
  final ValueChanged<LocalDate> onSelect;

  /// Previous month.
  final VoidCallback onPrevious;

  /// Next month.
  final VoidCallback onNext;

  /// Shown under the month header, for example the adherence numerals.
  final Widget? summary;

  @override
  Widget build(BuildContext context) {
    final extra = summary;
    return PillPalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MonthHeader(
            month: history.month,
            onPrevious: onPrevious,
            onNext: onNext,
          ),
          if (extra != null) ...[const Gap.v(PillPalSpacing.md), extra],
          const Gap.v(PillPalSpacing.lg),
          const _WeekdayRow(),
          const Gap.v(PillPalSpacing.sm),
          for (final week in _weeks())
            Row(
              children: [
                for (final cell in week)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: PillPalSpacing.xs / 2,
                      ),
                      child: cell,
                    ),
                  ),
              ],
            ),
          const Gap.v(PillPalSpacing.md),
          const _Legend(),
        ],
      ),
    );
  }

  /// The day cells in weeks of seven, Monday first, padded with blanks.
  List<List<Widget>> _weeks() {
    final cells = <Widget>[
      for (var i = 1; i < history.month.weekday; i++) const SizedBox.shrink(),
      for (final day in history.days)
        CalendarDayCell(
          key: ValueKey('day-${day.date}'),
          day: day,
          selected: day.date == selected,
          onTap: () => onSelect(day.date),
        ),
    ];
    while (cells.length % DateTime.daysPerWeek != 0) {
      cells.add(const SizedBox.shrink());
    }
    return [
      for (var row = 0; row < cells.length; row += DateTime.daysPerWeek)
        cells.sublist(row, row + DateTime.daysPerWeek),
    ];
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.month,
    required this.onPrevious,
    required this.onNext,
  });

  final LocalDate month;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Row(
      children: [
        PillPalIconButton(
          key: const Key('history-previous'),
          tooltip: l10n.previousMonth,
          icon: Icons.chevron_left,
          onPressed: onPrevious,
        ),
        Expanded(
          child: Text(
            formatMonthYear(month, locale),
            key: const Key('history-month'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        PillPalIconButton(
          key: const Key('history-next'),
          tooltip: l10n.nextMonth,
          icon: Icons.chevron_right,
          onPressed: onNext,
        ),
      ],
    );
  }
}

class _WeekdayRow extends StatelessWidget {
  const _WeekdayRow();

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Row(
      children: [
        for (var d = 1; d <= DateTime.daysPerWeek; d++)
          Expanded(
            // Never wider than its column, even at the largest text.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                formatWeekdayShort(d, locale),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
      ],
    );
  }
}

/// Round markers with the same glyphs as the cells, centred; wraps at large
/// text instead of overflowing.
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final style = Theme.of(context).textTheme.bodySmall;
    final marker = context.metrics.isSenior
        ? PillPalSizes.legendMarkerSenior
        : PillPalSizes.legendMarker;
    Widget item(DayAdherence adherence, String label) {
      final colors = dayCellColors(palette, adherence);
      final border = colors.border;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: marker,
            height: marker,
            decoration: BoxDecoration(
              color: colors.fill,
              shape: BoxShape.circle,
              border: border == null
                  ? null
                  : Border.all(
                      color: border,
                      width: dayCellBorderWidth(adherence),
                    ),
            ),
            child: Icon(
              dayCellIcon(adherence),
              size: calendarMarkSize(context),
              color: colors.text,
            ),
          ),
          const Gap.h(PillPalSpacing.xs),
          Flexible(child: Text(label, style: style)),
        ],
      );
    }

    return Wrap(
      key: const Key('history-legend'),
      alignment: WrapAlignment.center,
      runAlignment: WrapAlignment.center,
      spacing: PillPalSpacing.lg,
      runSpacing: PillPalSpacing.sm,
      children: [
        item(DayAdherence.allTaken, l10n.legendAllTaken),
        item(DayAdherence.partial, l10n.legendPartial),
        item(DayAdherence.missed, l10n.legendMissed),
      ],
    );
  }
}
