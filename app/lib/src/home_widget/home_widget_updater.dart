import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/clock.dart';
import '../data/db/database.dart';
import '../data/providers.dart';
import '../data/repositories/dose_event_queries.dart';
import '../features/common/local_time.dart';
import '../features/doses/scheduled_doses.dart';
import '../features/today/today_state.dart';
import '../reminders/providers.dart';
import '../reminders/reminder_content.dart';
import '../reminders/reminder_service.dart';
import '../reminders/reminder_settings_repository.dart';
import 'home_widget_channel.dart';
import 'today_widget_snapshot.dart';

/// The home-screen widget platform (tests override it with a fake).
final homeWidgetChannelProvider = Provider<HomeWidgetChannel>(
  (ref) => const PluginHomeWidgetChannel(),
);

/// Refreshes the Today widget; called after every re-plan.
final homeWidgetUpdaterProvider = Provider<HomeWidgetUpdater>(
  (ref) => HomeWidgetUpdater(
    db: ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
    deviceTimeZone: ref.watch(reminderTimeZoneSourceProvider),
    locale: () => ref.read(reminderLocaleProvider),
    channel: ref.watch(homeWidgetChannelProvider),
  ),
);

/// Writes today's and tomorrow's doses to the home-screen widget (TZ §2.6).
///
/// The app runs it after every reminder re-plan, which follows every write
/// to medications, schedules, dose events and reminder settings, app start,
/// resume and locale changes (ADR 0001 §9); a notification action handled
/// in the background runs it too. Reads the database directly, so it also
/// works in the background isolate (no providers there).
class HomeWidgetUpdater {
  /// Creates the updater.
  HomeWidgetUpdater({
    required AppDatabase db,
    required Clock clock,
    required TimeZoneSource deviceTimeZone,
    required LocaleSource locale,
    required HomeWidgetChannel channel,
  })  : _db = db,
        _clock = clock,
        _deviceTimeZone = deviceTimeZone,
        _locale = locale,
        _channel = channel;

  final AppDatabase _db;
  final Clock _clock;
  final TimeZoneSource _deviceTimeZone;
  final LocaleSource _locale;
  final HomeWidgetChannel _channel;

  /// Stores the current snapshot and redraws. Without a placed widget the
  /// data is removed instead, so no medication names sit in its storage.
  /// Failures leave the previous content (nothing is logged: the content is
  /// medical data).
  Future<void> refresh() async {
    if (!_channel.isSupported) {
      return;
    }
    try {
      if (!await _channel.hasWidgets()) {
        await _channel.remove(TodayWidgetKeys.all);
        return;
      }
      await _channel.save((await load()).toStorage());
      await _channel.redraw();
    } on Object {
      // Intentionally silent, see above.
    }
  }

  /// Replaces the content with an empty one ("open PillPal") and redraws:
  /// sign-out and account switch (ADR 0002 §1).
  Future<void> clear() async {
    if (!_channel.isSupported) {
      return;
    }
    try {
      final stale = reminderStrings(_locale()).widgetOpenApp;
      await _channel.remove(TodayWidgetKeys.all);
      await _channel.save(TodayWidgetSnapshot.empty(stale: stale).toStorage());
      await _channel.redraw();
    } on Object {
      // Intentionally silent, see above.
    }
  }

  /// The snapshot of today and tomorrow from the local database.
  Future<TodayWidgetSnapshot> load() async {
    final now = _clock();
    final profile = await (_db.select(_db.profiles)
          ..where((row) => row.kind.equals('self') & row.deletedAt.isNull()))
        .getSingleOrNull();
    final String tz = await _deviceTimeZone() ?? profile?.timezone ?? 'UTC';
    final medications = profile == null
        ? const <MedicationRow>[]
        : await (_db.select(_db.medications)
              ..where(
                (row) =>
                    row.profileId.equals(profile.id) & row.deletedAt.isNull(),
              ))
            .get();
    final schedules = parseSchedules(
      await (_db.select(_db.schedules)..where((row) => row.deletedAt.isNull()))
          .get(),
    );
    final today = localDateOf(now, tz);
    final tomorrow = today.addDays(1);
    final events = await selectDoseEventsForDays(
      _db,
      scheduleIds: [for (final schedule in schedules) schedule.row.id],
      firstDay: today.addDays(-1),
      lastDay: tomorrow.addDays(1),
      from: dayBounds(today, tz).start,
      to: dayBounds(tomorrow, tz).end,
    ).get();
    TodayState day(DateTime at) => buildTodayState(
          medications: medications,
          schedules: schedules,
          events: events,
          deviceTz: tz,
          now: at,
        );
    final hide = await ReminderSettingsRepository(_db).hideMedicationNames();
    return buildTodayWidgetSnapshot(
      [day(now), day(dayBounds(tomorrow, tz).start)],
      l10n: reminderStrings(_locale()),
      deviceTz: tz,
      hideMedicationNames: hide,
    );
  }
}
