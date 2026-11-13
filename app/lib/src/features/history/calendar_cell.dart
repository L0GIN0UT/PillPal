import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../common/formatters.dart';
import 'history_model.dart';

/// Fill, text and border of a day cell; colour is always paired with the
/// cell's semantics label, its glyph and the legend (docs/design.md).
///
/// A miss is `missed` (iris), never a red: the days of the month are
/// information, not an alarm (B2-README principle 3).
({Color fill, Color text, Color? border}) dayCellColors(
  PillPalPalette palette,
  DayAdherence adherence,
) {
  switch (adherence) {
    case DayAdherence.allTaken:
      return (fill: palette.taken, text: palette.onTaken, border: null);
    case DayAdherence.partial:
      // A hairline in `taken` keeps the pale disc visible on the card.
      return (
        fill: palette.takenSoft,
        text: palette.onTakenSoft,
        border: palette.taken,
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
      return (fill: palette.surface, text: palette.inkMuted, border: null);
  }
}

/// The glyph that repeats a day's colour (docs/design.md: colour is always
/// paired with an icon and a label); null for days without doses to judge.
/// The missed glyph is the one of the status pill.
IconData? dayCellIcon(DayAdherence adherence) {
  switch (adherence) {
    case DayAdherence.allTaken:
      return Icons.check_rounded;
    case DayAdherence.partial:
      return Icons.contrast;
    case DayAdherence.missed:
      return Icons.history;
    case DayAdherence.today:
    case DayAdherence.empty:
    case DayAdherence.future:
      return null;
  }
}

/// Width of the ring of a day: the hairline of a partial day, the 2 px ring
/// of today and of the selection.
double dayCellBorderWidth(DayAdherence adherence) =>
    adherence == DayAdherence.partial
        ? PillPalSizes.fieldBorder
        : PillPalSizes.outline;

/// Size of the glyph in a cell and the legend: larger in senior mode.
double calendarMarkSize(BuildContext context) => context.metrics.isSenior
    ? PillPalSizes.calendarMarkSenior
    : PillPalSizes.calendarMark;

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

/// One day of the grid: a round disc in the column, inside a tappable as high
/// as the touch target of the mode (seven columns cannot be a target wide).
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
    // Selected: an ink outer ring; a ring the day already has (today) stays
    // as the inner one.
    final ring = colors.border;
    final ringWidth = dayCellBorderWidth(day.adherence);
    final border = selected ? palette.ink : ring;
    return Semantics(
      button: true,
      selected: selected,
      label: '${formatDayMonth(day.date, locale)}: '
          '${adherenceLabel(l10n, day.adherence)}',
      excludeSemantics: true,
      onTap: onTap,
      // The whole cell is the touch target, but its ripple would paint a
      // square under the opaque disc: the target shows no ink, the disc
      // ripples as a circle.
      child: InkWell(
        onTap: onTap,
        splashFactory: NoSplash.splashFactory,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        child: SizedBox(
          height: context.metrics.touchTarget,
          child: Center(
            // Square, as wide as the column but never higher than the target.
            child: AspectRatio(
              aspectRatio: 1,
              child: Material(
                color: colors.fill,
                shape: CircleBorder(
                  side: border == null
                      ? BorderSide.none
                      : BorderSide(
                          color: border,
                          width: selected ? PillPalSizes.outline : ringWidth,
                        ),
                ),
                child: InkResponse(
                  onTap: onTap,
                  excludeFromSemantics: true,
                  containedInkWell: true,
                  highlightShape: BoxShape.rectangle,
                  customBorder: const CircleBorder(),
                  child: _DiscContent(
                    day: day.date.day,
                    icon: dayCellIcon(day.adherence),
                    color: colors.text,
                    innerRing: selected ? ring : null,
                    ringWidth: ringWidth,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DiscContent extends StatelessWidget {
  const _DiscContent({
    required this.day,
    required this.icon,
    required this.color,
    required this.innerRing,
    required this.ringWidth,
  });

  final int day;
  final IconData? icon;
  final Color color;

  /// The ring a selected day keeps inside the selection ring.
  final Color? innerRing;

  final double ringWidth;

  @override
  Widget build(BuildContext context) {
    final mark = icon;
    final ring = innerRing;
    final style =
        Theme.of(context).textTheme.labelLarge?.copyWith(color: color);
    return Container(
      margin: ring == null ? null : EdgeInsets.all(ringWidth),
      decoration: ring == null
          ? null
          : BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: ring, width: ringWidth),
            ),
      child: LayoutBuilder(
        builder: (context, constraints) => Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$day', style: style),
                if (mark != null && _glyphFits(context, style, constraints))
                  Icon(mark, size: calendarMarkSize(context), color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Whether the numeral at the current text scale and the glyph fit the
  /// disc together; if not the glyph is dropped so the numeral keeps its
  /// size (the legend and the semantics label carry the status).
  bool _glyphFits(
    BuildContext context,
    TextStyle? style,
    BoxConstraints constraints,
  ) {
    final line = MediaQuery.textScalerOf(context)
        .scale((style?.fontSize ?? 0) * (style?.height ?? 1));
    return line + calendarMarkSize(context) <= constraints.maxHeight;
  }
}
