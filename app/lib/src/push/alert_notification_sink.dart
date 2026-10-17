import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../l10n/gen/app_localizations.dart';
import 'relatives_alert_notifier.dart';

/// Android channel of the alerts about relatives (ADR 0001 §6: versioned ids,
/// a change of sound or importance needs a new one).
const String relativesAlertsChannelId = 'relatives_alerts_v1';

/// Android notification icon (kept from shrinking by `res/raw/keep.xml`).
const String _androidIcon = '@mipmap/ic_launcher';

/// The platform details of [notification] (Android only: iOS alerts are drawn
/// by the system from the APNs payload, with a generic localized key).
///
/// `private` visibility: on a secure lock screen the system shows its own
/// redacted version instead of the name and the text. The plugin has no way
/// to attach a custom public version (`setPublicVersion`), so the platform's
/// default redaction is what a lock screen shows (recorded in ADR 0008).
NotificationDetails alertNotificationDetails(
  AlertNotification notification,
  AppLocalizations strings,
) {
  return NotificationDetails(
    android: AndroidNotificationDetails(
      relativesAlertsChannelId,
      // Used only if the channel is missing; `prepare` creates it first.
      strings.relativesAlertChannelName,
      channelDescription: strings.relativesAlertChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      visibility: NotificationVisibility.private,
      styleInformation: BigTextStyleInformation(notification.body),
      silent: notification.quiet,
      onlyAlertOnce: notification.quiet,
    ),
  );
}

/// [AlertNotificationSink] over `flutter_local_notifications`, used from the
/// main isolate and from the background isolate of a data-only push.
class FlutterAlertNotificationSink implements AlertNotificationSink {
  /// Creates the sink over the plugin singleton.
  FlutterAlertNotificationSink(
    this._strings, [
    FlutterLocalNotificationsPlugin? plugin,
  ]) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final AppLocalizations _strings;
  final FlutterLocalNotificationsPlugin _plugin;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  /// Creates the channel (idempotent: an existing channel keeps the user's
  /// settings). With [initializePlugin], also initializes the plugin: a
  /// background isolate has its own plugin instance. The main isolate must
  /// not: its `initialize` call registered the response callbacks, and a
  /// second one without them would drop them.
  Future<void> prepare({bool initializePlugin = false}) async {
    if (initializePlugin) {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings(_androidIcon),
        ),
      );
    }
    await _android?.createNotificationChannel(
      AndroidNotificationChannel(
        relativesAlertsChannelId,
        _strings.relativesAlertChannelName,
        description: _strings.relativesAlertChannelDescription,
        importance: Importance.high,
      ),
    );
  }

  @override
  Future<void> show(AlertNotification notification) {
    return _plugin.show(
      id: notification.id,
      title: notification.title,
      body: notification.body,
      notificationDetails: alertNotificationDetails(notification, _strings),
      payload: notification.payload,
    );
  }

  @override
  Future<bool> isShown(int id) async {
    try {
      final active = await _plugin.getActiveNotifications();
      return active.any((notification) => notification.id == id);
    } on Object {
      return false;
    }
  }
}
