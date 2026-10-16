import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../common/formatters.dart';
import 'schedule_draft.dart';

/// Localized name of a rule kind ("Каждый день").
String ruleKindLabel(AppLocalizations l10n, RuleKind kind) {
  switch (kind) {
    case RuleKind.daily:
      return l10n.kindDaily;
    case RuleKind.weekdays:
      return l10n.kindWeekdays;
    case RuleKind.intervalDays:
      return l10n.kindInterval;
    case RuleKind.asNeeded:
      return l10n.kindAsNeeded;
  }
}

/// One-line summary: "Пн, Ср, Пт · 08:00, 20:00 · до 15 янв. 2027".
String scheduleSummary(
  AppLocalizations l10n,
  ScheduleRule rule,
  String locale,
) {
  final parts = <String>[];
  switch (rule.kind) {
    case RuleKind.daily:
      parts.add(l10n.kindDaily);
    case RuleKind.weekdays:
      final days = rule.weekdays ?? const <int>[];
      parts.add(days.map((d) => formatWeekdayShort(d, locale)).join(', '));
    case RuleKind.intervalDays:
      parts.add(l10n.everyNDays(rule.intervalDays ?? RuleLimits.minInterval));
    case RuleKind.asNeeded:
      parts.add(l10n.kindAsNeeded);
  }
  if (rule.times.isNotEmpty) {
    parts.add(rule.times.map((slot) => slot.time).join(', '));
  }
  final end = rule.endDate;
  if (end != null) {
    parts.add(l10n.courseUntil(formatShortDate(end, locale)));
  }
  return parts.join(' · ');
}

/// Localized editor error.
String scheduleErrorText(AppLocalizations l10n, ScheduleDraftError error) {
  switch (error) {
    case ScheduleDraftError.weekdaysEmpty:
      return l10n.scheduleErrorWeekdays;
    case ScheduleDraftError.timesEmpty:
      return l10n.scheduleErrorTimesEmpty;
    case ScheduleDraftError.timesDuplicate:
      return l10n.scheduleErrorTimesDuplicate;
    case ScheduleDraftError.amountInvalid:
      return l10n.scheduleErrorAmount;
    case ScheduleDraftError.endBeforeStart:
      return l10n.scheduleErrorEndBeforeStart;
    case ScheduleDraftError.intervalRange:
      return l10n.scheduleErrorInterval(
        RuleLimits.minInterval,
        RuleLimits.maxInterval,
      );
    case ScheduleDraftError.endBeforeToday:
      return l10n.scheduleErrorEndBeforeToday;
    case ScheduleDraftError.ended:
      return l10n.scheduleEndedNote;
    case ScheduleDraftError.ruleInvalid:
      return l10n.errorGeneric;
  }
}
