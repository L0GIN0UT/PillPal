import 'package:flutter/foundation.dart';

import '../../l10n/gen/app_localizations.dart';
import '../reminders/reminder_settings.dart';
import 'alert_local_data.dart';
import 'push_payload.dart';
import 'resolved_alerts.dart';

/// One notification to show or replace (Android channel
/// `relatives_alerts_v1`).
@immutable
class AlertNotification {
  /// Creates a notification.
  const AlertNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.payload,
    required this.publicTitle,
    required this.publicBody,
    this.quiet = false,
  });

  /// The notification id, in the app range (ADR 0001 §3).
  final int id;

  /// Title.
  final String title;

  /// Body: the detailed text, shown only where the lock screen allows it
  /// (`VISIBILITY_PRIVATE`, applied by the sink).
  final String body;

  /// Title of the redacted version a secure lock screen shows instead
  /// (`Notification.publicVersion`): the same neutral text for every alert.
  final String publicTitle;

  /// Body of the redacted version: names nobody and nothing medical.
  final String publicBody;

  /// What a tap opens: the compact JSON of the push (`PushPayload.encode`).
  final String payload;

  /// No sound or vibration: a repeat of what is already shown, or the
  /// follow-up that replaces an alert.
  final bool quiet;
}

/// The notification platform as the notifier needs it. The app uses
/// `PlatformAlertNotificationSink`; tests use a fake.
abstract interface class AlertNotificationSink {
  /// Shows [notification], replacing one with the same id.
  Future<void> show(AlertNotification notification);

  /// Whether a notification with [id] is in the tray now.
  Future<bool> isShown(int id);
}

/// Turns the data-only pushes of FCM and RuStore into local notifications
/// (ADR 0008 §2). A push carries ids only; the text comes from data already on
/// the device, so it works in a background isolate without network:
///
/// * the relative's display name, when known;
/// * a medication name only for a `shared` medication, while the device
///   setting "hide medication names" is off ([showsMedicationDetails]);
/// * otherwise a generic text, so nothing is guessed.
///
/// The notification id derives from the alert (`PushPayload.notificationId`):
/// `resolved` finds the `missed` notification and replaces it (and does
/// nothing when it is gone), and a repeated delivery replaces instead of
/// piling up. Never logs and never throws for missing local data.
class RelativesAlertNotifier {
  /// Creates the notifier. [toLocal] maps a UTC instant to the device's wall
  /// clock (injected for tests).
  RelativesAlertNotifier({
    required AlertLocalData data,
    required AlertNotificationSink sink,
    required ResolvedAlerts resolved,
    required AppLocalizations strings,
    DateTime Function(DateTime utc) toLocal = _deviceLocal,
  })  : _data = data,
        _sink = sink,
        _resolved = resolved,
        _strings = strings,
        _toLocal = toLocal;

  final AlertLocalData _data;
  final AlertNotificationSink _sink;
  final ResolvedAlerts _resolved;
  final AppLocalizations _strings;
  final DateTime Function(DateTime utc) _toLocal;

  static DateTime _deviceLocal(DateTime utc) => utc.toLocal();

  /// Shows (or replaces, or removes) the notification of [payload].
  Future<void> handle(PushPayload payload) async {
    switch (payload.kind) {
      case PushKind.missed:
        await _showMissed(payload);
      case PushKind.resolved:
        await _replaceWithResolved(payload);
      case PushKind.linkAccepted:
        await _showLink(
          payload,
          title: _strings.relativesAlertLinkAcceptedTitle,
          named: _strings.relativesAlertLinkAcceptedBody,
          generic: _strings.relativesAlertLinkAcceptedGenericBody,
        );
      case PushKind.linkRestored:
        await _showLink(
          payload,
          title: _strings.relativesAlertLinkRestoredTitle,
          named: _strings.relativesAlertLinkRestoredBody,
          generic: _strings.relativesAlertLinkRestoredGenericBody,
        );
    }
  }

  Future<void> _showMissed(PushPayload payload) async {
    final alertId = payload.alertId;
    if (alertId != null && await _resolved.wasResolved(alertId)) {
      // Deliveries are not ordered: this one was overtaken by its resolution.
      return;
    }
    final name = await _data.profileName(payload.profileId);
    final body = payload.unconfirmed
        ? await _unconfirmedBody(payload, name)
        : await _missedBody(payload, name);
    await _show(
      payload,
      title: _strings.relativesAlertMissedTitle,
      body: body,
    );
  }

  Future<String> _missedBody(PushPayload payload, String? name) async {
    if (name == null) {
      return _strings.relativesAlertMissedGenericBody;
    }
    final medication = await _shownMedicationName(payload);
    return medication == null
        ? _strings.relativesAlertMissedBody(name)
        : _strings.relativesAlertMissedMedicationBody(name, medication);
  }

  /// D5 (ADR 0007 §4): no confirmation because the owner's phone has not
  /// synced; the hour comes from the scope, never from the push.
  Future<String> _unconfirmedBody(PushPayload payload, String? name) async {
    final lastSeen = await _data.ownerLastSeenAt(payload.profileId);
    final time = lastSeen == null ? null : _hourText(_toLocal(lastSeen));
    if (name == null) {
      return time == null
          ? _strings.relativesAlertMissedGenericBody
          : _strings.relativesAlertUnconfirmedGenericBody(time);
    }
    return time == null
        ? _strings.relativesAlertUnconfirmedNoTimeBody(name)
        : _strings.relativesAlertUnconfirmedBody(name, time);
  }

  /// "HH:00": the server rounds the instant down to the hour, and so does
  /// this, so a zone with a half-hour offset still shows a whole hour.
  static String _hourText(DateTime local) =>
      '${local.hour.toString().padLeft(2, '0')}:00';

  Future<String?> _shownMedicationName(PushPayload payload) async {
    final id = payload.medicationId;
    if (id == null) {
      return null;
    }
    final medication = await _data.medication(payload.profileId, id);
    final name = medication?.name;
    if (medication == null || medication.redacted || name == null) {
      return null;
    }
    final shown = showsMedicationDetails(
      medication.privacy,
      hideMedicationNames: await _data.hideMedicationNames(),
    );
    return shown ? name : null;
  }

  /// The follow-up replaces the alert in place and without a sound; when the
  /// alert is not in the tray any more (dismissed, never shown) it would only
  /// be noise.
  Future<void> _replaceWithResolved(PushPayload payload) async {
    final alertId = payload.alertId;
    if (alertId != null) {
      await _resolved.remember(alertId);
    }
    if (!await _sink.isShown(payload.notificationId)) {
      return;
    }
    final name = await _data.profileName(payload.profileId);
    await _sink.show(
      _notification(
        payload,
        title: _strings.relativesAlertResolvedTitle,
        body: name == null
            ? _strings.relativesAlertResolvedGenericBody
            : _strings.relativesAlertResolvedBody(name),
        quiet: true,
      ),
    );
  }

  Future<void> _showLink(
    PushPayload payload, {
    required String title,
    required String Function(String name) named,
    required String generic,
  }) async {
    final grantId = payload.grantId;
    final name = grantId == null ? null : await _data.relativeName(grantId);
    await _show(
      payload,
      title: title,
      body: name == null ? generic : named(name),
    );
  }

  /// A delivery repeated for what is already shown makes no sound again.
  Future<void> _show(
    PushPayload payload, {
    required String title,
    required String body,
  }) async {
    await _sink.show(
      _notification(
        payload,
        title: title,
        body: body,
        quiet: await _sink.isShown(payload.notificationId),
      ),
    );
  }

  AlertNotification _notification(
    PushPayload payload, {
    required String title,
    required String body,
    required bool quiet,
  }) {
    return AlertNotification(
      id: payload.notificationId,
      title: title,
      body: body,
      payload: payload.encode(),
      publicTitle: _strings.relativesAlertPublicTitle,
      publicBody: _strings.relativesAlertPublicBody,
      quiet: quiet,
    );
  }
}
