import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:pillpal_core/pillpal_core.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../l10n/gen/app_localizations.dart';
import 'notification_scheduler.dart';

/// Category of reminder notifications on iOS (actions Taken/Snooze/Skip).
const String reminderCategoryId = 'reminder';

/// Android notification icon (kept from shrinking by `res/raw/keep.xml`).
const String _androidIcon = '@mipmap/ic_launcher';

/// `PlatformException.code` of a refused exact alarm (plugin, ADR §4).
const String _exactAlarmsNotPermittedCode = 'exact_alarms_not_permitted';

/// Alarm sound of the alarm channel.
const String _alarmSoundUri = 'content://settings/system/alarm_alert';

/// Channel ids per level. Android fixes sound, vibration and importance at
/// channel creation, so a change needs a new id (ADR 0001 §6).
String reminderChannelId(ReminderLevel level) => switch (level) {
      ReminderLevel.quiet => 'reminders_quiet_v1',
      ReminderLevel.normal => 'reminders_normal_v1',
      ReminderLevel.persistent => 'reminders_persistent_v1',
      ReminderLevel.alarm => 'reminders_alarm_v1',
    };

/// The Android schedule mode of a level (ADR 0001 §4).
AndroidScheduleMode reminderScheduleMode(
  ReminderLevel level, {
  required bool exact,
}) {
  if (!exact) {
    return AndroidScheduleMode.inexactAllowWhileIdle;
  }
  return level == ReminderLevel.alarm
      ? AndroidScheduleMode.alarmClock
      : AndroidScheduleMode.exactAllowWhileIdle;
}

/// The iOS interruption level of a level (ADR 0001 §6).
InterruptionLevel reminderInterruptionLevel(ReminderLevel level) =>
    switch (level) {
      ReminderLevel.quiet => InterruptionLevel.passive,
      ReminderLevel.normal => InterruptionLevel.active,
      ReminderLevel.persistent => InterruptionLevel.timeSensitive,
      ReminderLevel.alarm => InterruptionLevel.timeSensitive,
    };

/// [NotificationScheduler] over `flutter_local_notifications` (ADR 0001).
///
/// Every notification is scheduled at a UTC instant (ADR §2). Android
/// notifications carry no `groupKey`: without a group summary Android does
/// not bundle a group (it shows the children one by one, and Android 15+
/// force-groups summary-less children into an app-wide group), so the
/// system's own auto-grouping is used instead; settling an occurrence
/// cancels all of its notifications anyway. iOS threads by occurrence.
class FlutterNotificationScheduler implements NotificationScheduler {
  /// Creates the adapter over the plugin singleton.
  FlutterNotificationScheduler([FlutterLocalNotificationsPlugin? plugin])
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  IOSFlutterLocalNotificationsPlugin? get _ios =>
      _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();

  /// Initializes the plugin in the main isolate: action category (iOS),
  /// channels (Android) and the response callbacks. Permissions are not
  /// requested here but from the onboarding card.
  Future<void> initialize({
    required AppLocalizations strings,
    required DidReceiveNotificationResponseCallback onResponse,
    required DidReceiveBackgroundNotificationResponseCallback onBackground,
  }) async {
    await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings(_androidIcon),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
          notificationCategories: [
            DarwinNotificationCategory(
              reminderCategoryId,
              actions: [
                DarwinNotificationAction.plain(
                  ReminderActionIds.taken,
                  strings.reminderActionTaken,
                ),
                DarwinNotificationAction.plain(
                  ReminderActionIds.snooze,
                  strings.reminderActionSnooze,
                ),
                DarwinNotificationAction.plain(
                  ReminderActionIds.skip,
                  strings.reminderActionSkip,
                ),
              ],
            ),
          ],
        ),
      ),
      onDidReceiveNotificationResponse: onResponse,
      onDidReceiveBackgroundNotificationResponse: onBackground,
    );
    await _createChannels(strings);
  }

  /// The response that launched the app, if a notification did.
  Future<NotificationResponse?> launchResponse() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    return details != null && details.didNotificationLaunchApp
        ? details.notificationResponse
        : null;
  }

  /// Asks for the notification permission (Android 13+, iOS); true if
  /// granted.
  Future<bool> requestNotifications() async {
    final android = _android;
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }
    final ios = _ios;
    if (ios != null) {
      return await ios.requestPermissions(
            alert: true,
            sound: true,
            badge: true,
          ) ??
          false;
    }
    return false;
  }

  /// Opens the system screen for exact alarms (Android 12+); true if
  /// granted afterwards.
  Future<bool> requestExactAlarms() async =>
      await _android?.requestExactAlarmsPermission() ?? true;

  /// Opens the app's notification settings.
  Future<void> openNotificationSettings() async {
    await _plugin.openAppNotificationSettings();
  }

  @override
  Future<ReminderPermissions> permissions() async {
    final android = _android;
    if (android != null) {
      return ReminderPermissions(
        notificationsEnabled: await android.areNotificationsEnabled() ?? false,
        exactAlarmsAllowed:
            await android.canScheduleExactNotifications() ?? false,
      );
    }
    final ios = _ios;
    if (ios != null) {
      final options = await ios.checkPermissions();
      return ReminderPermissions(
        notificationsEnabled: options?.isEnabled ?? false,
        exactAlarmsAllowed: true,
      );
    }
    return const ReminderPermissions(
      notificationsEnabled: false,
      exactAlarmsAllowed: false,
    );
  }

  @override
  Future<Set<int>> pendingIds() async {
    final pending = await _plugin.pendingNotificationRequests();
    return {for (final request in pending) request.id};
  }

  @override
  Future<void> schedule(ScheduledReminder reminder) async {
    try {
      await _plugin.zonedSchedule(
        id: reminder.id,
        scheduledDate: tz.TZDateTime.from(reminder.fireAtUtc, tz.UTC),
        notificationDetails: _details(reminder),
        androidScheduleMode:
            reminderScheduleMode(reminder.level, exact: reminder.exact),
        title: reminder.title,
        body: reminder.body,
        payload: reminder.payload,
      );
    } on PlatformException catch (error) {
      if (error.code == _exactAlarmsNotPermittedCode) {
        throw const ExactAlarmsNotPermitted();
      }
      rethrow;
    }
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);

  /// Android: every alarm the plugin stored plus `NotificationManager
  /// .cancelAll()`; iOS: all pending and delivered requests.
  @override
  Future<void> cancelAll() => _plugin.cancelAll();

  NotificationDetails _details(ScheduledReminder reminder) {
    final level = reminder.level;
    final alarm = level == ReminderLevel.alarm;
    return NotificationDetails(
      android: AndroidNotificationDetails(
        reminderChannelId(level),
        // Used only if the channel is missing; [initialize] creates and
        // names every channel first.
        reminderChannelId(level),
        importance: _importance(level),
        priority: level == ReminderLevel.quiet ? Priority.low : Priority.high,
        playSound: level != ReminderLevel.quiet,
        enableVibration: level != ReminderLevel.quiet,
        category: alarm
            ? AndroidNotificationCategory.alarm
            : AndroidNotificationCategory.reminder,
        audioAttributesUsage: alarm
            ? AudioAttributesUsage.alarm
            : AudioAttributesUsage.notification,
        sound: alarm ? const UriAndroidNotificationSound(_alarmSoundUri) : null,
        channelAction: AndroidNotificationChannelAction.createIfNotExists,
        actions: [
          AndroidNotificationAction(
            ReminderActionIds.taken,
            reminder.actions.taken,
          ),
          AndroidNotificationAction(
            ReminderActionIds.snooze,
            reminder.actions.snooze,
          ),
          AndroidNotificationAction(
            ReminderActionIds.skip,
            reminder.actions.skip,
          ),
        ],
      ),
      iOS: DarwinNotificationDetails(
        categoryIdentifier: reminderCategoryId,
        threadIdentifier: reminder.threadId,
        interruptionLevel: reminderInterruptionLevel(level),
        presentSound: level != ReminderLevel.quiet,
      ),
    );
  }

  Future<void> _createChannels(AppLocalizations strings) async {
    final android = _android;
    if (android == null) {
      return;
    }
    for (final level in ReminderLevel.values) {
      final alarm = level == ReminderLevel.alarm;
      final quiet = level == ReminderLevel.quiet;
      await android.createNotificationChannel(
        AndroidNotificationChannel(
          reminderChannelId(level),
          _localizedChannelName(strings, level),
          importance: _importance(level),
          playSound: !quiet,
          enableVibration: !quiet,
          sound:
              alarm ? const UriAndroidNotificationSound(_alarmSoundUri) : null,
          audioAttributesUsage: alarm
              ? AudioAttributesUsage.alarm
              : AudioAttributesUsage.notification,
        ),
      );
    }
  }

  static String _localizedChannelName(
    AppLocalizations strings,
    ReminderLevel level,
  ) =>
      switch (level) {
        ReminderLevel.quiet => strings.reminderChannelQuiet,
        ReminderLevel.normal => strings.reminderChannelNormal,
        ReminderLevel.persistent => strings.reminderChannelPersistent,
        ReminderLevel.alarm => strings.reminderChannelAlarm,
      };

  static Importance _importance(ReminderLevel level) => switch (level) {
        ReminderLevel.quiet => Importance.low,
        ReminderLevel.normal => Importance.high,
        ReminderLevel.persistent => Importance.high,
        ReminderLevel.alarm => Importance.max,
      };
}

/// Whether the platform has a notification plugin (false in widget tests).
bool get notificationsSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);
