import '../../../l10n/gen/app_localizations.dart';

/// Part of the day a dose is grouped under (B2-HistoryDay, senior Today).
enum DayPart {
  /// Before noon.
  morning,

  /// From noon to 18:00.
  day,

  /// From 18:00 on.
  evening,
}

/// First hour of [DayPart.day] and [DayPart.evening].
const int _dayPartDayHour = 12;
const int _dayPartEveningHour = 18;

/// The part of the day of a wall-clock time `HH:MM`.
DayPart dayPartOf(String time) {
  final hour = int.parse(time.substring(0, 2));
  if (hour < _dayPartDayHour) {
    return DayPart.morning;
  }
  return hour < _dayPartEveningHour ? DayPart.day : DayPart.evening;
}

/// The name of [part] in the language of [l10n].
String dayPartLabel(AppLocalizations l10n, DayPart part) => switch (part) {
      DayPart.morning => l10n.dayPartMorning,
      DayPart.day => l10n.dayPartDay,
      DayPart.evening => l10n.dayPartEvening,
    };
