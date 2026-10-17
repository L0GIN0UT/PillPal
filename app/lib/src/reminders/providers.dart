import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth/access_claims.dart';
import '../data/providers.dart';
import '../features/common/local_time.dart';
import '../features/report/report_files.dart';
import '../home_widget/home_widget_updater.dart';
import '../push/push_providers.dart';
import '../routing/router.dart';
import '../settings/app_settings.dart';
import 'background_handler.dart';
import 'device_platform.dart';
import 'flutter_notification_scheduler.dart';
import 'notification_scheduler.dart';
import 'reminder_controller.dart';
import 'reminder_service.dart';
import 'reminder_session.dart';
import 'reminder_settings.dart';
import 'reminder_settings_repository.dart';

// Reminder wiring (milestone 2.3). Tests override
// [notificationSchedulerProvider] (fake), [reminderPermissionActionsProvider],
// [reminderTimeZoneSourceProvider] (or `timeZoneReaderProvider`),
// [devicePlatformProvider] and the data-layer
// providers (`databaseProvider`, `clockProvider`).

/// The notification plugin adapter (main isolate).
final flutterNotificationSchedulerProvider =
    Provider<FlutterNotificationScheduler>(
  (ref) => FlutterNotificationScheduler(),
);

/// The platform as the reminder service sees it.
final notificationSchedulerProvider = Provider<NotificationScheduler>(
  (ref) => ref.watch(flutterNotificationSchedulerProvider),
);

/// The device's IANA zone (`flutter_timezone`): the same source the screens
/// derive "today" from, so reminders and Today agree on the zone.
final reminderTimeZoneSourceProvider = Provider<TimeZoneSource>(
  (ref) => ref.watch(timeZoneReaderProvider),
);

/// Notification budget of this platform.
final reminderBudgetProvider = Provider<int>(
  (ref) => platformNotificationBudget(),
);

/// The language notifications are rendered in: the app's language, else
/// the system's.
final reminderLocaleProvider = Provider<Locale>(
  (ref) =>
      ref.watch(settingsProvider).locale ?? PlatformDispatcher.instance.locale,
);

/// Device-local reminder settings.
final reminderSettingsRepositoryProvider = Provider<ReminderSettingsRepository>(
  (ref) => ReminderSettingsRepository(ref.watch(databaseProvider)),
);

/// The default reminder settings.
final reminderDefaultsProvider = StreamProvider<ReminderSettings>(
  (ref) => ref.watch(reminderSettingsRepositoryProvider).watchDefaults(),
);

/// Whether reminders hide medication names (device setting).
final reminderHideNamesProvider = StreamProvider<bool>(
  (ref) =>
      ref.watch(reminderSettingsRepositoryProvider).watchHideMedicationNames(),
);

/// A medication's own settings; null while it follows the defaults.
///
/// Auto-disposed: one stream per medication screen visited would otherwise
/// stay open for the app's lifetime.
final medicationReminderOverrideProvider =
    StreamProvider.autoDispose.family<ReminderSettings?, String>(
  (ref, medicationId) =>
      ref.watch(reminderSettingsRepositoryProvider).watchOverride(medicationId),
);

/// The reminder service.
final reminderServiceProvider = Provider<ReminderService>((ref) {
  final service = ReminderService(
    db: ref.watch(databaseProvider),
    scheduler: ref.watch(notificationSchedulerProvider),
    clock: ref.watch(clockProvider),
    deviceTimeZone: ref.watch(reminderTimeZoneSourceProvider),
    locale: () => ref.read(reminderLocaleProvider),
    budget: ref.watch(reminderBudgetProvider),
    rearmOnFirstReplan: defaultTargetPlatform == TargetPlatform.android,
  );
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

/// The session listener that also clears reminders on sign-out and on an
/// account switch.
final reminderSessionListenerProvider = Provider<SessionListener>(
  (ref) => ReminderSessionListener(
    binding: ref.watch(accountBindingProvider),
    clearReminders: ref.watch(reminderServiceProvider).clearAll,
    clearHomeWidget: ref.watch(homeWidgetUpdaterProvider).clear,
    clearReportFiles: ref.watch(reportFilesProvider).clear,
    // Read lazily: the push service depends on the API client, which owns
    // this listener.
    clearPush: () => ref.read(pushServiceProvider).sessionEnded(),
  ),
);

/// Overrides `main.dart` installs: the data layer's session listener
/// becomes [reminderSessionListenerProvider].
final List<Override> reminderAppOverrides = [
  sessionListenerProvider.overrideWith(
    (ref) => ref.watch(reminderSessionListenerProvider),
  ),
];

/// Latest reminder status (permissions, truncated plan, unknown zones).
final reminderStatusProvider =
    NotifierProvider<ReminderStatusNotifier, ReminderStatus>(
  ReminderStatusNotifier.new,
);

/// Mirrors [ReminderService.statusChanges].
class ReminderStatusNotifier extends Notifier<ReminderStatus> {
  @override
  ReminderStatus build() {
    final service = ref.watch(reminderServiceProvider);
    final subscription = service.statusChanges.listen((status) {
      state = status;
    });
    ref.onDispose(() => unawaited(subscription.cancel()));
    return service.status;
  }
}

/// Re-plan triggers; started by `ReminderScope`.
final reminderControllerProvider = Provider<ReminderController>((ref) {
  final controller = ReminderController(
    db: ref.watch(databaseProvider),
    service: ref.watch(reminderServiceProvider),
    clock: ref.watch(clockProvider),
    locale: () => ref.read(reminderLocaleProvider),
    platform: notificationsSupported
        ? ref.watch(flutterNotificationSchedulerProvider)
        : null,
    onOpenToday: () => ref.read(routerProvider).go(AppRoutes.today),
    onSyncNeeded: () => unawaited(ref.read(syncEngineProvider).sync()),
    onReplanned: () => unawaited(ref.read(homeWidgetUpdaterProvider).refresh()),
  );
  ref.onDispose(() => unawaited(controller.stop()));
  return controller;
});

/// Re-plans now, e.g. after a permission screen returns.
final reminderRefreshProvider = Provider<Future<void> Function()>(
  (ref) => ref.watch(reminderControllerProvider).replanNow,
);

/// Manufacturer channel and battery settings (Android).
final devicePlatformProvider = Provider<DevicePlatform>(
  (ref) => const DevicePlatform(),
);

/// Vendor name for the battery hint, or null when the phone needs none.
final batteryHintVendorProvider = FutureProvider<String?>((ref) async {
  final manufacturer = await ref.watch(devicePlatformProvider).manufacturer();
  return batteryHintVendor(manufacturer);
});

/// Permission requests behind the onboarding card.
abstract interface class ReminderPermissionActions {
  /// Asks for the notification permission; true if granted.
  Future<bool> requestNotifications();

  /// Opens the exact-alarm setting; true if granted.
  Future<bool> requestExactAlarms();

  /// Opens the battery-optimisation settings.
  Future<bool> openBatterySettings();

  /// Opens the app's notification settings (iOS Time Sensitive switch).
  Future<bool> openNotificationSettings();
}

class _PlatformPermissionActions implements ReminderPermissionActions {
  _PlatformPermissionActions(this._scheduler, this._device);

  final FlutterNotificationScheduler _scheduler;
  final DevicePlatform _device;

  @override
  Future<bool> requestNotifications() => _scheduler.requestNotifications();

  @override
  Future<bool> requestExactAlarms() => _scheduler.requestExactAlarms();

  @override
  Future<bool> openBatterySettings() => _device.openBatterySettings();

  @override
  Future<bool> openNotificationSettings() =>
      _scheduler.openNotificationSettings();
}

/// The platform's permission requests.
final reminderPermissionActionsProvider = Provider<ReminderPermissionActions>(
  (ref) => _PlatformPermissionActions(
    ref.watch(flutterNotificationSchedulerProvider),
    ref.watch(devicePlatformProvider),
  ),
);
