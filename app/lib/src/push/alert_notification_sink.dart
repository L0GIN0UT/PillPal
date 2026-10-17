import '../../l10n/gen/app_localizations.dart';
import 'alert_platform.dart';
import 'relatives_alert_notifier.dart';

/// Android channel of the alerts about relatives (ADR 0001 §6: versioned ids,
/// a change of sound or importance needs a new one).
const String relativesAlertsChannelId = 'relatives_alerts_v1';

/// [AlertNotificationSink] over the native alerts plugin, used from the main
/// isolate and from the background isolate of a data-only push.
///
/// The notification has private visibility and a redacted public version
/// (`AlertNotification.publicTitle` and `publicBody`): on a secure lock screen
/// the system shows the public one, so names and medications are read only
/// after unlocking (ADR 0008 §2).
class PlatformAlertNotificationSink implements AlertNotificationSink {
  /// Creates the sink.
  PlatformAlertNotificationSink(this._strings, this._platform);

  final AppLocalizations _strings;
  final AlertPlatform _platform;

  /// Creates the channel (idempotent).
  Future<void> prepare() {
    return _platform.prepare(
      channelId: relativesAlertsChannelId,
      name: _strings.relativesAlertChannelName,
      description: _strings.relativesAlertChannelDescription,
    );
  }

  @override
  Future<void> show(AlertNotification notification) {
    return _platform.show({
      'id': notification.id,
      'channelId': relativesAlertsChannelId,
      'title': notification.title,
      'body': notification.body,
      'publicTitle': notification.publicTitle,
      'publicBody': notification.publicBody,
      'payload': notification.payload,
      'quiet': notification.quiet,
    });
  }

  @override
  Future<bool> isShown(int id) => _platform.isShown(id);
}
