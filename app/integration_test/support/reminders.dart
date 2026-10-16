import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal/src/reminders/providers.dart';
import 'package:pillpal/src/reminders/reminder_payload.dart';
import 'package:pillpal/src/reminders/reminder_status.dart';

// Reads of the real notification plugin (not the app's adapter), so the
// journeys check what the platform holds.

/// Synthetic medication of the journeys. The workflow looks for this name
/// in the delivered notification (`.github/scripts/emulator/run.sh`).
const String journeyMedicationName = 'Testamin';

final FlutterLocalNotificationsPlugin _plugin =
    FlutterLocalNotificationsPlugin();

/// Occurrence key of a reminder notification's payload, if it is one.
String? occurrenceKeyOf(String? payload) =>
    ReminderPayload.tryDecode(payload)?.occurrenceKey;

/// The pending (scheduled) notifications of occurrence [key].
Future<List<PendingNotificationRequest>> pendingFor(String key) async => [
      for (final request in await _plugin.pendingNotificationRequests())
        if (occurrenceKeyOf(request.payload) == key) request,
    ];

/// All pending notifications of the app.
Future<List<PendingNotificationRequest>> allPending() =>
    _plugin.pendingNotificationRequests();

/// The app's notifications in the tray.
Future<List<ActiveNotification>> activeNotifications() =>
    _plugin.getActiveNotifications();

/// The latest reminder status of the running app.
ReminderStatus reminderStatus(ProviderContainer container) =>
    container.read(reminderStatusProvider);

/// Whether a re-plan has succeeded with at least one notification.
bool hasPlanned(ProviderContainer container) {
  final status = reminderStatus(container);
  return status.plannedAt != null && !status.failed && status.planned > 0;
}
