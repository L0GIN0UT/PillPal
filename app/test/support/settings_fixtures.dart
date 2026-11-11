import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal/src/data/api/auth_api.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/sync/sync_status.dart';
import 'package:pillpal/src/features/catalog/catalog_providers.dart';
import 'package:pillpal/src/features/settings/account_section.dart';
import 'package:pillpal/src/reminders/notification_scheduler.dart';
import 'package:pillpal/src/reminders/providers.dart';
import 'package:pillpal/src/reminders/reminder_service.dart';
import 'package:pillpal/src/reminders/reminder_settings.dart';
import 'package:pillpal/src/reminders/reminder_settings_repository.dart';
import 'package:pillpal_core/pillpal_core.dart';

// Fixtures of the Settings screen tests: no database, network or platform.

/// The e-mail of the fake account (synthetic).
const String settingsFixtureEmail = 'mama.test@example.org';

class _IdleSync extends SyncStatusNotifier {
  @override
  SyncStatus build() => const SyncStatus();
}

class _FixedStatus extends ReminderStatusNotifier {
  _FixedStatus(this._status);

  final ReminderStatus _status;

  @override
  ReminderStatus build() => _status;
}

class _NoopRepository implements ReminderSettingsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

/// Answers `GET /v1/me` only.
class _FakeAuthApi implements AuthApi {
  @override
  Future<UserInfo> me() async => const UserInfo(
        id: 'user-1',
        email: settingsFixtureEmail,
        emailVerified: true,
        region: 'ru',
        locale: 'ru',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Persistent reminders every 30 minutes, five times.
final ReminderSettings settingsFixturePersistent = ReminderSettings(
  level: ReminderLevel.persistent,
  repeatEveryMinutes: 30,
  maxRepeats: 5,
);

/// Notifications are off: a blocking problem.
const ReminderStatus noNotificationsStatus = ReminderStatus(
  permissions: ReminderPermissions(
    notificationsEnabled: false,
    exactAlarmsAllowed: false,
  ),
);

/// Exact alarms are off: a hint.
const ReminderStatus noExactAlarmsStatus = ReminderStatus(
  permissions: ReminderPermissions(
    notificationsEnabled: true,
    exactAlarmsAllowed: false,
  ),
);

/// Time Sensitive is off: a hint.
const ReminderStatus noTimeSensitiveStatus = ReminderStatus(
  permissions: ReminderPermissions(
    notificationsEnabled: true,
    exactAlarmsAllowed: true,
    timeSensitiveAllowed: false,
  ),
  timeSensitiveDegraded: true,
);

/// Everything Settings reads, replaced by fixed values.
List<Override> settingsOverrides({
  ReminderStatus status = const ReminderStatus(),
  String? vendor,
  int pending = 0,
  bool catalog = true,
}) =>
    [
      syncStatusProvider.overrideWith(_IdleSync.new),
      pendingChangesProvider.overrideWith((ref) => Stream.value(pending)),
      catalogEnabledProvider.overrideWithValue(catalog),
      authApiProvider.overrideWithValue(_FakeAuthApi()),
      reminderSettingsRepositoryProvider.overrideWithValue(_NoopRepository()),
      reminderDefaultsProvider
          .overrideWith((ref) => Stream.value(settingsFixturePersistent)),
      reminderHideNamesProvider.overrideWith((ref) => Stream.value(false)),
      reminderStatusProvider.overrideWith(() => _FixedStatus(status)),
      batteryHintVendorProvider.overrideWith((ref) async => vendor),
    ];
