import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/sync/sync_status.dart';
import 'package:pillpal/src/features/catalog/catalog_providers.dart';
import 'package:pillpal/src/features/common/banner_tone.dart';
import 'package:pillpal/src/features/common/choice_button.dart';
import 'package:pillpal/src/features/common/choice_group.dart';
import 'package:pillpal/src/features/common/group_label.dart';
import 'package:pillpal/src/features/common/pillpal_banner.dart';
import 'package:pillpal/src/features/reminders/reminder_level_picker.dart';
import 'package:pillpal/src/features/reminders/reminder_permission_card.dart';
import 'package:pillpal/src/features/reminders/reminder_settings_sections.dart';
import 'package:pillpal/src/features/settings/account_section.dart';
import 'package:pillpal/src/features/settings/settings_screen.dart';
import 'package:pillpal/src/reminders/notification_scheduler.dart';
import 'package:pillpal/src/reminders/providers.dart';
import 'package:pillpal/src/reminders/reminder_service.dart';
import 'package:pillpal/src/reminders/reminder_settings.dart';
import 'package:pillpal/src/reminders/reminder_settings_repository.dart';
import 'package:pillpal/src/theme/radius.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../support/ui_matrix.dart';

// Settings and reminder screens of the UI consistency pass (UI-3).

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

final _persistent = ReminderSettings(
  level: ReminderLevel.persistent,
  repeatEveryMinutes: 30,
  maxRepeats: 5,
);

const _noNotifications = ReminderStatus(
  permissions: ReminderPermissions(
    notificationsEnabled: false,
    exactAlarmsAllowed: false,
  ),
);

const _noExactAlarms = ReminderStatus(
  permissions: ReminderPermissions(
    notificationsEnabled: true,
    exactAlarmsAllowed: false,
  ),
);

const _noTimeSensitive = ReminderStatus(
  permissions: ReminderPermissions(
    notificationsEnabled: true,
    exactAlarmsAllowed: true,
    timeSensitiveAllowed: false,
  ),
  timeSensitiveDegraded: true,
);

List<Override> _overrides({
  ReminderStatus status = const ReminderStatus(),
  String? vendor,
}) =>
    [
      syncStatusProvider.overrideWith(_IdleSync.new),
      pendingChangesProvider.overrideWith((ref) => Stream.value(0)),
      catalogEnabledProvider.overrideWithValue(true),
      reminderSettingsRepositoryProvider.overrideWithValue(_NoopRepository()),
      reminderDefaultsProvider.overrideWith((ref) => Stream.value(_persistent)),
      reminderHideNamesProvider.overrideWith((ref) => Stream.value(false)),
      reminderStatusProvider.overrideWith(() => _FixedStatus(status)),
      batteryHintVendorProvider.overrideWith((ref) async => vendor),
    ];

Widget _host(Widget child, {List<Override>? overrides}) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ProviderScope(
        overrides: overrides ?? _overrides(),
        child: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

void main() {
  group('matrix', () {
    testWidgets('SettingsScreen', (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => ProviderScope(
          overrides: _overrides(),
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height,
            width: MediaQuery.sizeOf(context).width,
            child: const SettingsScreen(),
          ),
        ),
        check: (tester, cell) async {
          await tester.pump();
          expect(find.byType(ChoiceGroup<ThemeMode>), findsOneWidget);
          // The list builds lazily: scroll to the end and check what shows.
          await tester.scrollUntilVisible(
            find.byKey(const Key('sign-out')),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.byKey(const Key('settings-catalog-sources')),
              findsOneWidget);
          expectTouchTargetsOf(tester, cell);
        },
        expectTouchTargets: true,
      );
    });

    testWidgets('reminder defaults section with repeats', (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => ProviderScope(
          overrides: _overrides(),
          child: const SingleChildScrollView(child: ReminderDefaultsSection()),
        ),
        check: (tester, cell) async {
          await tester.pump();
          expect(
            find.byKey(const ValueKey('reminder-level-alarm')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('reminder-interval-30')),
            findsOneWidget,
          );
        },
        expectTouchTargets: true,
      );
    });

    testWidgets('permission card in every state', (tester) async {
      for (final status in [
        _noNotifications,
        _noExactAlarms,
        _noTimeSensitive,
      ]) {
        await pumpUiMatrix(
          tester,
          (context) => ProviderScope(
            overrides: _overrides(status: status),
            child: const SingleChildScrollView(
              child: ReminderPermissionCard(),
            ),
          ),
          check: (tester, cell) async {
            await tester.pump();
            expect(find.byType(PillPalBanner), findsOneWidget);
          },
          expectTouchTargets: true,
        );
      }
    });
  });

  group('settings', () {
    testWidgets('choices are ChoiceGroups under GroupLabels', (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProviderScope(
            overrides: _overrides(),
            child: const SettingsScreen(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ChoiceGroup<ThemeMode>), findsOneWidget);
      expect(find.byType(ChoiceGroup<LanguageChoice>), findsOneWidget);
      expect(find.byType(GroupLabel), findsWidgets);
      expect(
        find.byKey(const Key('settings-catalog-sources')),
        findsOneWidget,
      );
    });

    testWidgets('sign-out dialog follows the confirm dialog layout',
        (tester) async {
      await tester.pumpWidget(_host(const SignOutButton()));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sign-out')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('confirm-sign-out')), findsOneWidget);
    });
  });

  group('reminders', () {
    testWidgets('interval and repeat choices are ChoiceButtons',
        (tester) async {
      await tester.pumpWidget(
        _host(ReminderLevelPicker(value: _persistent, onChanged: (_) {})),
      );
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byType(ChoiceGroup<int>), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('reminder-interval-30')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('reminder-repeats-5')), findsOneWidget);
    });

    BannerTone toneOf(WidgetTester tester, String key) =>
        tester.widget<PillPalBanner>(find.byKey(ValueKey(key))).tone;

    Future<void> pumpCard(WidgetTester tester, ReminderStatus status) async {
      await tester.pumpWidget(
        _host(
          const ReminderPermissionCard(),
          overrides: _overrides(status: status),
        ),
      );
      await tester.pump();
    }

    testWidgets('blocking permission is a danger banner', (tester) async {
      await pumpCard(tester, _noNotifications);
      expect(
        toneOf(tester, 'reminder-permission-notifications'),
        BannerTone.danger,
      );
    });

    testWidgets('the exact alarms hint is a soft banner', (tester) async {
      await pumpCard(tester, _noExactAlarms);
      expect(toneOf(tester, 'reminder-permission-exact'), BannerTone.soft);
    });

    testWidgets('the Focus hint is a soft banner', (tester) async {
      await pumpCard(tester, _noTimeSensitive);
      expect(toneOf(tester, 'reminder-time-sensitive-hint'), BannerTone.soft);
    });
  });

  testWidgets('ChoiceButton uses the small radius', (tester) async {
    await tester.pumpWidget(
      _host(ChoiceButton(label: 'x', selected: false, onTap: () {})),
    );
    final material = tester.widget<Material>(
      find.descendant(
        of: find.byType(ChoiceButton),
        matching: find.byType(Material),
      ),
    );
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(PillPalRadius.sm));
  });
}
