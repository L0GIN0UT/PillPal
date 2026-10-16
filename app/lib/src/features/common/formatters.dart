import 'package:intl/intl.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';

/// Display helpers shared by the screens. All text comes from ARB files;
/// dates and numbers use `intl` with the active locale.

/// The unit word agreeing with [count] ("1 таблетка", "2 таблетки").
String doseUnitLabel(AppLocalizations l10n, DoseUnit unit, num count) {
  switch (unit) {
    case DoseUnit.tablet:
      return l10n.unitTablet(count);
    case DoseUnit.capsule:
      return l10n.unitCapsule(count);
    case DoseUnit.ml:
      return l10n.unitMl(count);
    case DoseUnit.mg:
      return l10n.unitMg(count);
    case DoseUnit.drop:
      return l10n.unitDrop(count);
    case DoseUnit.puff:
      return l10n.unitPuff(count);
    case DoseUnit.sachet:
      return l10n.unitSachet(count);
    case DoseUnit.unit:
      return l10n.unitUnit(count);
    case DoseUnit.injection:
      return l10n.unitInjection(count);
    case DoseUnit.other:
      return l10n.unitOther(count);
  }
}

/// The dose unit with wire name [name], or [DoseUnit.other].
DoseUnit doseUnitOf(String name) {
  for (final unit in DoseUnit.values) {
    if (unit.name == name) {
      return unit;
    }
  }
  return DoseUnit.other;
}

/// A decimal amount string ("0.5") in the locale's notation ("0,5").
String formatAmount(String amount, String locale) {
  final value = num.tryParse(amount);
  if (value == null) {
    return amount;
  }
  // Display only: the stored amount stays the exact decimal string.
  return NumberFormat('#,##0.###', locale).format(value);
}

/// "1 таблетка", "0,5 таблетки".
String formatDose(
  AppLocalizations l10n,
  String amount,
  String unitName,
  String locale,
) {
  final count = num.tryParse(amount) ?? 1;
  final unit = doseUnitLabel(l10n, doseUnitOf(unitName), count);
  return '${formatAmount(amount, locale)} $unit';
}

/// Capitalizes the first letter (Russian month and weekday names are
/// lower-case in `intl`).
String capitalize(String text) =>
    text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

DateTime _asDateTime(LocalDate date) =>
    DateTime(date.year, date.month, date.day);

/// "Пятница, 16 октября" / "Friday, October 16".
String formatLongDate(LocalDate date, String locale) =>
    capitalize(DateFormat.MMMMEEEEd(locale).format(_asDateTime(date)));

/// "16 октября" / "October 16".
String formatDayMonth(LocalDate date, String locale) =>
    DateFormat.MMMMd(locale).format(_asDateTime(date));

/// "16 окт. 2026" / "Oct 16, 2026".
String formatShortDate(LocalDate date, String locale) =>
    DateFormat.yMMMd(locale).format(_asDateTime(date));

/// "Октябрь 2026" / "October 2026".
String formatMonthYear(LocalDate date, String locale) =>
    capitalize(DateFormat('LLLL y', locale).format(_asDateTime(date)));

/// Stand-alone month name: "октябрь" / "October".
String formatMonthName(LocalDate date, String locale) =>
    DateFormat('LLLL', locale).format(_asDateTime(date));

/// Short weekday for ISO [weekday] (1 = Monday): "Пн" / "Mon".
String formatWeekdayShort(int weekday, String locale) {
  // 2024-01-01 was a Monday.
  final date = DateTime(2024, 1, weekday);
  final text = DateFormat.E(locale).format(date).replaceAll('.', '');
  return capitalize(text);
}
