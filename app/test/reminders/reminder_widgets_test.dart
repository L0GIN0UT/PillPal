import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/reminders/reminder_level_picker.dart';
import 'package:pillpal/src/features/reminders/reminder_permission_card.dart';
import 'package:pillpal/src/features/reminders/reminder_settings_sections.dart';
import 'package:pillpal/src/reminders/device_platform.dart';
import 'package:pillpal/src/reminders/notification_scheduler.dart';
import 'package:pillpal/src/reminders/providers.dart';
import 'package:pillpal/src/reminders/reminder_service.dart';
import 'package:pillpal/src/reminders/reminder_settings.dart';
import 'package:pillpal/src/reminders/reminder_settings_repository.dart';
import 'package:pillpal_core/pillpal_core.dart';

class _FixedStatus extends ReminderStatusNotifier {
  _FixedStatus(this._status);

  final ReminderStatus _status;

  @override
  ReminderStatus build() => _status;
}

class _FakeActions implements ReminderPermissionActions {
  final List<String> calls = [];

  @override
  Future<bool> requestNotifications() async {
    calls.add('notifications');
    return true;
  }

  @override
  Future<bool> requestExactAlarms() async {
    calls.add('exact');
    return true;
  }

  @override
  Future<bool> openBatterySettings() async {
    calls.add('battery');
    return true;
  }
}

class _RecordingSettings implements ReminderSettingsRepository {
  final List<bool> hidden = [];

  @override
  Future<void> setHideMedicationNames({required bool hide}) async {
    hidden.add(hide);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

void main() {
  group('ReminderLevelPicker', () {
    testWidgets('picks a level and, for repeating ones, N and M',
        (tester) async {
      var value = ReminderSettings.builtIn;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) => ReminderLevelPicker(
              value: value,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      );
      expect(find.text('Repeat every'), findsNothing);

      await tester.tap(find.text('Persistent'));
      await tester.pumpAndSettle();
      expect(value.level, ReminderLevel.persistent);
      expect(find.text('Repeat every'), findsOneWidget);

      for (final key in ['reminder-interval-30', 'reminder-repeats-5']) {
        final chip = find.byKey(ValueKey(key));
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
      }

      expect(
        value,
        ReminderSettings(
          level: ReminderLevel.persistent,
          repeatEveryMinutes: 30,
          maxRepeats: 5,
        ),
      );
      expect(find.text('5 times'), findsOneWidget);
    });
  });

  testWidgets('ReminderDefaultsSection toggles hiding medication names',
      (tester) async {
    final settings = _RecordingSettings();
    await tester.pumpWidget(
      _app(
        const ReminderDefaultsSection(),
        overrides: [
          reminderSettingsRepositoryProvider.overrideWithValue(settings),
          reminderDefaultsProvider.overrideWith(
            (ref) => Stream.value(ReminderSettings.builtIn),
          ),
          reminderHideNamesProvider.overrideWith((ref) => Stream.value(false)),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('reminder-hide-names'));
    expect(find.text('Hide medication names in notifications'), findsOneWidget);

    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(settings.hidden, [true]);
  });

  group('ReminderPermissionCard', () {
    late _FakeActions actions;
    late int refreshes;

    List<Override> overrides(ReminderPermissions permissions, String? vendor) {
      return [
        reminderStatusProvider.overrideWith(
          () => _FixedStatus(ReminderStatus(permissions: permissions)),
        ),
        reminderPermissionActionsProvider.overrideWithValue(actions),
        reminderRefreshProvider.overrideWithValue(() async {
          refreshes++;
        }),
        batteryHintVendorProvider.overrideWith((ref) async => vendor),
      ];
    }

    setUp(() {
      actions = _FakeActions();
      refreshes = 0;
    });

    testWidgets('asks for notifications first', (tester) async {
      await tester.pumpWidget(
        _app(
          const ReminderPermissionCard(),
          overrides: overrides(
            const ReminderPermissions(
              notificationsEnabled: false,
              exactAlarmsAllowed: false,
            ),
            'Xiaomi',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Notifications are off'), findsOneWidget);

      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();

      expect(actions.calls, ['notifications']);
      expect(refreshes, 1);
    });

    testWidgets('then exact alarms', (tester) async {
      await tester.pumpWidget(
        _app(
          const ReminderPermissionCard(),
          overrides: overrides(
            const ReminderPermissions(
              notificationsEnabled: true,
              exactAlarmsAllowed: false,
            ),
            null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Reminders may be late'), findsOneWidget);

      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();

      expect(actions.calls, ['exact']);
    });

    testWidgets('battery hint on known vendors, dismissible', (tester) async {
      await tester.pumpWidget(
        _app(
          const ReminderPermissionCard(),
          overrides: overrides(ReminderPermissions.unknown, 'Xiaomi'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('On Xiaomi phones'), findsOneWidget);

      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(actions.calls, ['battery']);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('nothing when all is well', (tester) async {
      await tester.pumpWidget(
        _app(
          const ReminderPermissionCard(),
          overrides: overrides(ReminderPermissions.unknown, null),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsNothing);
    });
  });

  test('battery hint vendors', () {
    expect(batteryHintVendor('Xiaomi'), 'Xiaomi');
    expect(batteryHintVendor(' redmi '), 'Xiaomi');
    expect(batteryHintVendor('samsung'), 'Samsung');
    expect(batteryHintVendor('Google'), isNull);
    expect(batteryHintVendor(null), isNull);
  });
}
