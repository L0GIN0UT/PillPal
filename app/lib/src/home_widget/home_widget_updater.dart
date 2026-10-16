import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../data/providers.dart';
import '../features/common/local_time.dart';
import '../features/doses/scheduled_doses.dart';
import '../features/today/today_state.dart';
import '../reminders/providers.dart';
import '../reminders/reminder_content.dart';
import 'home_widget_channel.dart';
import 'today_widget_snapshot.dart';

/// The home-screen widget platform (tests override it with a fake).
final homeWidgetChannelProvider = Provider<HomeWidgetChannel>(
  (ref) => const PluginHomeWidgetChannel(),
);

/// Refreshes the Today widget; called after every re-plan.
final homeWidgetUpdaterProvider = Provider<HomeWidgetUpdater>(
  HomeWidgetUpdater.new,
);

/// Writes today's doses to the home-screen widget (TZ §2.6).
///
/// It runs after every reminder re-plan, which follows every write to
/// medications, schedules, dose events and reminder settings (local,
/// synced or from a notification action), app start, resume and locale
/// changes (ADR 0001 §9).
class HomeWidgetUpdater {
  /// Creates the updater.
  HomeWidgetUpdater(this._ref);

  final Ref<Object?> _ref;

  /// Stores the current snapshot and redraws; failures leave the previous
  /// content (nothing is logged: the content is medical data).
  Future<void> refresh() async {
    final channel = _ref.read(homeWidgetChannelProvider);
    if (!channel.isSupported) {
      return;
    }
    try {
      final snapshot = await load();
      await channel.save(snapshot.toStorage());
      await channel.redraw();
      await channel.scheduleRedraws(snapshot.redrawAt);
    } on Object {
      // Intentionally silent, see above.
    }
  }

  /// The snapshot of today from the local database.
  Future<TodayWidgetSnapshot> load() async {
    final now = _ref.read(clockProvider)();
    final String? platformZone =
        await _ref.read(reminderTimeZoneSourceProvider)();
    final String tz = platformZone ?? _ref.read(deviceTimeZoneProvider);
    final profiles =
        await _ref.read(profilesRepositoryProvider).watchAll().first;
    final self = profiles.where((p) => p.kind == 'self').firstOrNull;
    final medications = self == null
        ? const <MedicationRow>[]
        : await _ref
            .read(medicationsRepositoryProvider)
            .watchForProfile(self.id)
            .first;
    final schedules = parseSchedules(
      await _ref.read(schedulesRepositoryProvider).watchAll().first,
    );
    final today = localDateOf(now, tz);
    final bounds = dayBounds(today, tz);
    final events = await _ref.read(doseEventsRepositoryProvider).watchForDays(
      scheduleIds: [for (final schedule in schedules) schedule.row.id],
      firstDay: today.addDays(-1),
      lastDay: today.addDays(1),
      from: bounds.start,
      to: bounds.end,
    ).first;
    final state = buildTodayState(
      medications: medications,
      schedules: schedules,
      events: events,
      deviceTz: tz,
      now: now,
    );
    final hide = await _ref
        .read(reminderSettingsRepositoryProvider)
        .hideMedicationNames();
    return buildTodayWidgetSnapshot(
      state,
      l10n: reminderStrings(_ref.read(reminderLocaleProvider)),
      deviceTz: tz,
      hideMedicationNames: hide,
    );
  }
}
