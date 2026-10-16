import 'package:flutter/material.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../common/formatters.dart';
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
      return (
        fill: palette.actionSoft,
        text: palette.onActionSoft,
        border: palette.action,
      );
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
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MonthHeader(
              month: history.month,
              onPrevious: onPrevious,
              onNext: onNext,
            ),
            const SizedBox(height: 8),
            const _WeekdayRow(),
            const SizedBox(height: 6),
            for (final week in _weeks())
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    for (final cell in week)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: cell,
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
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
        IconButton(
          key: const Key('history-previous'),
          tooltip: l10n.previousMonth,
          icon: const Icon(Icons.chevron_left),
          onPressed: onPrevious,
        ),
        IconButton(
          key: const Key('history-next'),
          tooltip: l10n.nextMonth,
          icon: const Icon(Icons.chevron_right),
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
            child: Text(
              formatWeekdayShort(d, locale),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall,
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
    final border = selected ? palette.ink : colors.border;
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
          borderRadius: BorderRadius.circular(12),
          side: border == null
              ? BorderSide.none
              : BorderSide(color: border, width: 2),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(
            height: context.metrics.touchTarget,
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
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w800,
              ),
        ),
        if (mark != null) Icon(mark, size: 12, color: color),
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
    Widget item(DayAdherence adherence, String label) {
      final colors = dayCellColors(palette, adherence);
      final border = colors.border;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: colors.fill,
              borderRadius: BorderRadius.circular(4),
              border:
                  border == null ? null : Border.all(color: border, width: 1.5),
            ),
            child: Icon(dayCellIcon(adherence), size: 12, color: colors.text),
          ),
          const SizedBox(width: 6),
          Text(label, style: style),
        ],
      );
    }

    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        item(DayAdherence.allTaken, l10n.legendAllTaken),
        item(DayAdherence.partial, l10n.legendPartial),
        item(DayAdherence.missed, l10n.legendMissed),
      ],
    );
  }
}
