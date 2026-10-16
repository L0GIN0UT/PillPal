import '../../l10n/gen/app_localizations.dart';
import '../features/common/local_time.dart';
import '../features/today/dose_tile.dart';
import '../features/today/today_state.dart';
import '../reminders/reminder_settings.dart';

// What the Android home-screen widget shows (TZ §2.6): the next dose and
// "N из M сегодня". The widget runs no Dart and arms no alarms (the exact
// alarm quota belongs to reminders): the app stores the open doses of today
// and tomorrow with their instants and each day's progress, and the native
// provider picks the day and the first dose still ahead whenever the
// launcher draws it. The app rewrites the data after every write.

/// Separates the fields of one line.
const String widgetFieldSeparator = '\u001f';

/// Separates lines.
const String widgetEntrySeparator = '\n';

/// Keys of the widget storage (read by `TodayWidgetProvider.kt`).
abstract final class TodayWidgetKeys {
  /// "Следующий приём".
  static const String nextLabel = 'today_next_label';

  /// Days: `startMillis \x1f endMillis \x1f progress` per line.
  static const String days = 'today_days';

  /// Open doses: `dueMillis \x1f HH:MM \x1f title` per line, by time.
  static const String entries = 'today_entries';

  /// Shown when no open dose is ahead on the current day.
  static const String noneLeft = 'today_none_left';

  /// End of the last stored day (epoch milliseconds).
  static const String validUntil = 'today_valid_until';

  /// Shown after [validUntil] (or with nothing stored).
  static const String stale = 'today_stale';

  /// Every key, for clearing.
  static const List<String> all = [
    nextLabel,
    days,
    entries,
    noneLeft,
    validUntil,
    stale,
  ];
}

/// One open dose for the widget.
class WidgetDose {
  /// Creates an entry.
  const WidgetDose({
    required this.dueAt,
    required this.time,
    required this.title,
  });

  /// When it is due (UTC).
  final DateTime dueAt;

  /// Local time `HH:MM`.
  final String time;

  /// Medication name, or the generic text (privacy).
  final String title;
}

/// One stored day.
class WidgetDay {
  /// Creates a day.
  const WidgetDay({
    required this.start,
    required this.end,
    required this.progress,
    required this.doses,
  });

  /// Start of the day (UTC).
  final DateTime start;

  /// End of the day (UTC).
  final DateTime end;

  /// "N из M сегодня".
  final String progress;

  /// Doses still open, by time.
  final List<WidgetDose> doses;
}

/// The widget's content.
class TodayWidgetSnapshot {
  /// Creates a snapshot.
  const TodayWidgetSnapshot({
    required this.days,
    required this.nextLabel,
    required this.noneLeft,
    required this.stale,
  });

  /// The content shown after sign-out: no data, only [stale].
  const TodayWidgetSnapshot.empty({required this.stale})
      : days = const [],
        nextLabel = '',
        noneLeft = '';

  /// Today and tomorrow.
  final List<WidgetDay> days;

  /// "Следующий приём".
  final String nextLabel;

  /// "Больше приёмов сегодня нет".
  final String noneLeft;

  /// "Откройте PillPal".
  final String stale;

  /// End of the last day; the epoch when there is none.
  DateTime get validUntil => days.isEmpty ? DateTime.utc(1970) : days.last.end;

  /// The widget storage values.
  Map<String, String> toStorage() => {
        TodayWidgetKeys.nextLabel: nextLabel,
        TodayWidgetKeys.noneLeft: noneLeft,
        TodayWidgetKeys.stale: stale,
        TodayWidgetKeys.validUntil: '${validUntil.millisecondsSinceEpoch}',
        TodayWidgetKeys.days: [
          for (final day in days)
            [
              '${day.start.millisecondsSinceEpoch}',
              '${day.end.millisecondsSinceEpoch}',
              _plain(day.progress),
            ].join(widgetFieldSeparator),
        ].join(widgetEntrySeparator),
        TodayWidgetKeys.entries: [
          for (final day in days)
            for (final dose in day.doses)
              [
                '${dose.dueAt.millisecondsSinceEpoch}',
                dose.time,
                _plain(dose.title),
              ].join(widgetFieldSeparator),
        ].join(widgetEntrySeparator),
      };
}

/// Drops the separators (and other control characters) from a text.
String _plain(String text) =>
    text.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ');

/// The widget content of [days] (today, tomorrow; pure). Names follow the
/// notification rules (`showsMedicationDetails`): `hidden`/`anonymous`
/// medications, or all of them when [hideMedicationNames], show a generic
/// text.
TodayWidgetSnapshot buildTodayWidgetSnapshot(
  List<TodayState> days, {
  required AppLocalizations l10n,
  required String deviceTz,
  required bool hideMedicationNames,
}) {
  WidgetDay day(TodayState state) {
    final bounds = dayBounds(state.date, deviceTz);
    final total = state.doses.length;
    return WidgetDay(
      start: bounds.start,
      end: bounds.end,
      progress: total == 0
          ? l10n.widgetNoDosesToday
          : l10n.widgetProgress(state.takenCount, total),
      doses: [
        for (final dose in state.doses)
          if (dose.isOpen)
            WidgetDose(
              dueAt: dose.dueAt,
              time: doseTime(dose, deviceTz),
              title: showsMedicationDetails(
                dose.medication.privacy,
                hideMedicationNames: hideMedicationNames,
              )
                  ? medicationTitle(dose)
                  : l10n.widgetGenericDose,
            ),
      ],
    );
  }

  return TodayWidgetSnapshot(
    days: [for (final state in days) day(state)],
    nextLabel: l10n.seniorNext,
    noneLeft: l10n.widgetNoneLeft,
    stale: l10n.widgetOpenApp,
  );
}
