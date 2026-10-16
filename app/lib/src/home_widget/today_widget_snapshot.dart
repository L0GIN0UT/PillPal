import '../../l10n/gen/app_localizations.dart';
import '../features/common/local_time.dart';
import '../features/doses/dose_status.dart';
import '../features/today/dose_tile.dart';
import '../features/today/today_state.dart';
import '../reminders/reminder_settings.dart';

// What the Android home-screen widget shows (TZ §2.6): the next dose and
// "N из M сегодня". The widget runs no Dart: the app stores today's open
// doses with their instants, and the native provider picks the first one
// still ahead each time it redraws (scheduled at those instants), so the
// widget stays right between app launches.

/// Separates the fields of one dose entry.
const String widgetFieldSeparator = '\u001f';

/// Separates dose entries.
const String widgetEntrySeparator = '\n';

/// Keys of the widget storage (read by `TodayWidgetProvider.kt`).
abstract final class TodayWidgetKeys {
  /// "Следующий приём".
  static const String nextLabel = 'today_next_label';

  /// "3 из 5 сегодня".
  static const String progress = 'today_progress';

  /// Open doses: `dueMillis \x1f HH:MM \x1f title` per line, by time.
  static const String entries = 'today_entries';

  /// Shown when no open dose is ahead today.
  static const String noneLeft = 'today_none_left';

  /// End of the day the entries belong to (epoch milliseconds).
  static const String validUntil = 'today_valid_until';

  /// Shown after [validUntil] until the app refreshes the widget.
  static const String stale = 'today_stale';
}

/// One open dose for the widget.
class WidgetDose {
  /// Creates an entry.
  const WidgetDose({required this.dueAt, required this.time, required this.title});

  /// When it is due (UTC).
  final DateTime dueAt;

  /// Local time `HH:MM`.
  final String time;

  /// Medication name, or the generic text (privacy).
  final String title;
}

/// The widget's content.
class TodayWidgetSnapshot {
  /// Creates a snapshot.
  const TodayWidgetSnapshot({
    required this.doses,
    required this.progress,
    required this.nextLabel,
    required this.noneLeft,
    required this.stale,
    required this.validUntil,
  });

  /// Doses still open today, by time.
  final List<WidgetDose> doses;

  /// "N из M сегодня".
  final String progress;

  /// "Следующий приём".
  final String nextLabel;

  /// "Больше приёмов сегодня нет".
  final String noneLeft;

  /// "Откройте PillPal".
  final String stale;

  /// End of today (UTC).
  final DateTime validUntil;

  /// The instants the widget must redraw at: each dose's end of grace (it
  /// is no longer "next" then) and the end of the day.
  List<DateTime> get redrawAt => [
        for (final dose in doses) dose.dueAt.add(DoseTiming.missedGrace),
        validUntil,
      ];

  /// The widget storage values.
  Map<String, String> toStorage() => {
        TodayWidgetKeys.nextLabel: nextLabel,
        TodayWidgetKeys.progress: progress,
        TodayWidgetKeys.noneLeft: noneLeft,
        TodayWidgetKeys.stale: stale,
        TodayWidgetKeys.validUntil: '${validUntil.millisecondsSinceEpoch}',
        TodayWidgetKeys.entries: [
          for (final dose in doses)
            [
              '${dose.dueAt.millisecondsSinceEpoch}',
              dose.time,
              _plain(dose.title),
            ].join(widgetFieldSeparator),
        ].join(widgetEntrySeparator),
      };
}

/// Drops the separators (and other control characters) from a title.
String _plain(String text) =>
    text.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ');

/// The widget content of [state] (pure). Names follow the notification
/// rules (`showsMedicationDetails`): `hidden`/`anonymous` medications, or
/// all of them when [hideMedicationNames], show a generic text.
TodayWidgetSnapshot buildTodayWidgetSnapshot(
  TodayState state, {
  required AppLocalizations l10n,
  required String deviceTz,
  required bool hideMedicationNames,
}) {
  final total = state.doses.length;
  return TodayWidgetSnapshot(
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
    progress: total == 0
        ? l10n.widgetNoDosesToday
        : l10n.widgetProgress(state.takenCount, total),
    nextLabel: l10n.seniorNext,
    noneLeft: l10n.widgetNoneLeft,
    stale: l10n.widgetOpenApp,
    validUntil: dayBounds(state.date, deviceTz).end,
  );
}
