import 'dart:ui';

import 'package:firebase_messaging/firebase_messaging.dart';

import '../../l10n/gen/app_localizations.dart';
import '../data/db/database.dart';
import '../reminders/reminder_content.dart';
import 'alert_local_data.dart';
import 'alert_notification_sink.dart';
import 'push_channel.dart';
import 'push_payload.dart';
import 'relatives_alert_notifier.dart';

/// Renders the data of a push as a notification from local data: parses it
/// strictly (anything that is not ours is dropped), and runs the notifier.
/// Never throws and logs nothing: a push that cannot be shown is lost, and
/// its content may be medical.
Future<void> handlePushData(
  Map<String, String> data, {
  required Future<AlertLocalData> Function() openData,
  required AlertNotificationSink Function(AppLocalizations strings) openSink,
  required AppLocalizations strings,
  required Future<void> Function() close,
}) async {
  final payload = PushPayload.tryParse(data);
  if (payload == null) {
    return;
  }
  try {
    final sink = openSink(strings);
    final notifier = RelativesAlertNotifier(
      data: await openData(),
      sink: sink,
      strings: strings,
    );
    await notifier.handle(payload);
  } on Object {
    // Intentionally silent, see above.
  } finally {
    await close();
  }
}

/// Entry point of FCM data-only pushes while the app is in the background
/// or terminated: an own isolate, no network, no sync. The default Firebase
/// app is created by the plugin from the `google_app_id` resources that
/// Gradle writes, so nothing is initialized here.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  DartPluginRegistrant.ensureInitialized();
  final data = stringData(message.data);
  if (PushPayload.tryParse(data) == null) {
    return;
  }
  final strings = reminderStrings(PlatformDispatcher.instance.locale);
  AppDatabase? db;
  await handlePushData(
    data,
    strings: strings,
    openData: () async {
      final opened = AppDatabase.open();
      db = opened;
      return DriftAlertLocalData(opened);
    },
    openSink: (strings) {
      final sink = FlutterAlertNotificationSink(strings);
      return _PreparedSink(sink);
    },
    close: () async => db?.close(),
  );
}

/// Prepares the plugin (own instance in this isolate) before the first
/// notification.
class _PreparedSink implements AlertNotificationSink {
  _PreparedSink(this._inner);

  final FlutterAlertNotificationSink _inner;
  Future<void>? _prepared;

  Future<void> _prepare() => _prepared ??= _inner.prepare(
        initializePlugin: true,
      );

  @override
  Future<void> show(AlertNotification notification) async {
    await _prepare();
    await _inner.show(notification);
  }

  @override
  Future<bool> isShown(int id) async {
    await _prepare();
    return _inner.isShown(id);
  }
}
