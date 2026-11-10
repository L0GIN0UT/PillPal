import 'package:flutter/material.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import '../common/formatters.dart';
import '../common/gap.dart';
import '../common/pillpal_icon_button.dart';
import 'history_model.dart';

/// Fill, text and border of a day cell; colour is always paired with the
/// cell's semantics label and the legend (docs/design.md).
({Color fill, Color text, Color? border}) dayCellColors(
  PillPalPalette palette,
  DayAdherence adherence,
) {
  switch (adherence) {
    case DayAdherence.allTaken:
      return (fill: palette.taken, text: palette.onTaken, border: null);
    case DayAdherence.partial:
      // One sage scale (D6): a lighter taken, ink on it, no outline.
      return (fill: palette.takenSoft, text: palette.ink, border: null);
    case DayAdherence.missed:
      return (fill: palette.missed, text: palette.onMissed, border: null);
    case DayAdherence.today:
      return (
        fill: palette.surface,
        text: palette.action,
        border: palette.action
      );
    case DayAdherence.empty:
      return (fill: palette.surface, text: palette.ink, border: null);
    case DayAdherence.future:
      return (fill: palette.background, text: palette.inkMuted, border: null);
  }
}

/// The icon that repeats a day's colour (docs/design.md: colour is always
/// paired with an icon and a label); null for days without doses to judge.
IconData? dayCellIcon(DayAdherence adherence) {
  switch (adherence) {
    case DayAdherence.allTaken:
      return Icons.check_rounded;
    case DayAdherence.partial:
      return Icons.remove_rounded;
    case DayAdherence.missed:
      return Icons.close_rounded;
    case DayAdherence.today:
    case DayAdherence.empty:
    case DayAdherence.future:
      return null;
  }
}

/// Size of the status mark in a cell and the legend: larger in senior mode.
double _calendarMark(BuildContext context) =>
    context.metrics.touchTarget == PillPalSizes.touchTarget
        ? PillPalSizes.calendarMark
        : PillPalSizes.calendarMarkSenior;

/// Month grid, Monday first, with legend; own widget (no package).
class MonthCalendar extends StatelessWidget {
  /// Creates the calendar.
  const MonthCalendar({
    required this.history,
    required this.selected,
    required this.onSelect,
    required this.onPrevious,
    required this.onNext,
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

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: PillPalSpacing.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MonthHeader(
              month: history.month,
              onPrevious: onPrevious,
              onNext: onNext,
            ),
            const Gap.v(PillPalSpacing.sm),
            const _WeekdayRow(),
            const Gap.v(PillPalSpacing.xs),
            for (final week in _weeks())
              Padding(
                padding: const EdgeInsets.only(bottom: PillPalSpacing.xs),
                child: Row(
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
              ),
            const Gap.v(PillPalSpacing.sm),
            const _Legend(),
          ],
        ),
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
        Expanded(
          child: Text(
            formatMonthYear(month, locale),
            key: const Key('history-month'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        PillPalIconButton(
          key: const Key('history-previous'),
          tooltip: l10n.previousMonth,
          icon: Icons.chevron_left,
          onPressed: onPrevious,
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

/// One day of the grid.
class CalendarDayCell extends StatelessWidget {
  /// Creates the cell.
  const CalendarDayCell({
    required this.day,
    required this.selected,
    required this.onTap,
    super.key,
  });

  /// The day.
  final DayHistory day;

  /// Whether it is selected.
  final bool selected;

  /// Tap handler.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final colors = dayCellColors(palette, day.adherence);
    // Selected: an ink outer border; a ring the day already has (today)
    // stays as the inner one.
    final ring = colors.border;
    final border = selected ? palette.ink : ring;
    return Semantics(
      button: true,
      selected: selected,
      label: '${formatDayMonth(day.date, locale)}: '
          '${adherenceLabel(l10n, day.adherence)}',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: colors.fill,
        shape: RoundedRectangleBorder(
          borderRadius: PillPalRadius.chip,
          side: border == null
              ? BorderSide.none
              : BorderSide(color: border, width: PillPalSizes.outline),
        ),
        child: InkWell(
          borderRadius: PillPalRadius.chip,
          onTap: onTap,
          child: Container(
            height: context.metrics.touchTarget,
            margin: selected && ring != null
                ? const EdgeInsets.all(PillPalSizes.outline)
                : null,
            decoration: selected && ring != null
                ? BoxDecoration(
                    borderRadius: PillPalRadius.chip,
                    border: Border.all(
                      color: ring,
                      width: PillPalSizes.outline,
                    ),
                  )
                : null,
            child: Center(
              child: FittedBox(
                child: _CellContent(
                  day: day.date.day,
                  icon: dayCellIcon(day.adherence),
                  color: colors.text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CellContent extends StatelessWidget {
  const _CellContent({
    required this.day,
    required this.icon,
    required this.color,
  });

  final int day;
  final IconData? icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final mark = icon;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$day',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(color: color),
        ),
        if (mark != null)
          Icon(mark, size: _calendarMark(context), color: color),
      ],
    );
  }
}

/// Localized description of a day's adherence.
String adherenceLabel(AppLocalizations l10n, DayAdherence adherence) {
  switch (adherence) {
    case DayAdherence.allTaken:
      return l10n.dayAllTaken;
    case DayAdherence.partial:
      return l10n.dayPartial;
    case DayAdherence.missed:
      return l10n.dayMissed;
    case DayAdherence.today:
      return l10n.dayToday;
    case DayAdherence.empty:
      return l10n.dayEmpty;
    case DayAdherence.future:
      return l10n.dayFuture;
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final style = Theme.of(context).textTheme.bodySmall;
    final marker = context.metrics.touchTarget == PillPalSizes.touchTarget
        ? PillPalSizes.legendMarker
        : PillPalSizes.legendMarkerSenior;
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
                  : Border.all(color: border, width: PillPalSizes.outline),
            ),
            child: Icon(
              dayCellIcon(adherence),
              size: _calendarMark(context),
              color: colors.text,
            ),
          ),
          const Gap.h(PillPalSpacing.xs),
          // Wraps instead of overflowing at large text sizes.
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
