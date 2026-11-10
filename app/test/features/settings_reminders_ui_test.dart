import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/l10n/gen/app_localizations_en.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/sync/sync_status.dart';
import 'package:pillpal/src/features/auth/auth_session.dart';
import 'package:pillpal/src/features/catalog/catalog_providers.dart';
import 'package:pillpal/src/features/common/banner_tone.dart';
import 'package:pillpal/src/features/common/choice_button.dart';
import 'package:pillpal/src/features/common/choice_group.dart';
import 'package:pillpal/src/features/common/group_label.dart';
import 'package:pillpal/src/features/common/pillpal_banner.dart';
import 'package:pillpal/src/features/common/removal_dialog.dart';
import 'package:pillpal/src/features/reminders/reminder_level_picker.dart';
import 'package:pillpal/src/features/reminders/reminder_permission_card.dart';
import 'package:pillpal/src/features/reminders/reminder_settings_sections.dart';
import 'package:pillpal/src/features/settings/account_section.dart';
import 'package:pillpal/src/features/settings/settings_screen.dart';
import 'package:pillpal/src/features/stock/stock_providers.dart';
import 'package:pillpal/src/features/stock/stock_widgets.dart';
import 'package:pillpal/src/reminders/notification_scheduler.dart';
import 'package:pillpal/src/reminders/providers.dart';
import 'package:pillpal/src/reminders/reminder_service.dart';
import 'package:pillpal/src/reminders/reminder_settings.dart';
import 'package:pillpal/src/reminders/reminder_settings_repository.dart';
import 'package:pillpal/src/theme/palette.dart';
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

class _RecordingStock implements StockActions {
  _RecordingStock(this.saved);

  final List<String> saved;

  @override
  Future<void> setStock(String id, String count) async =>
      saved.add('$id:$count');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
      for (final (status, vendor) in <(ReminderStatus, String?)>[
        (_noNotifications, null),
        (_noExactAlarms, null),
        (_noTimeSensitive, null),
        (const ReminderStatus(), 'xiaomi'),
      ]) {
        await pumpUiMatrix(
          tester,
          (context) => ProviderScope(
            overrides: _overrides(status: status, vendor: vendor),
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

    testWidgets('sign-out is a danger dialog: destructive button first',
        (tester) async {
      await tester.pumpWidget(_host(const SignOutButton()));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sign-out')));
      await tester.pumpAndSettle();

      final signOut = find.byKey(const Key('confirm-sign-out'));
      final fill = tester
          .widget<FilledButton>(signOut)
          .style
          ?.backgroundColor
          ?.resolve(const {});
      expect(fill, PillPalPalette.light.danger);
      expect(
        tester.getTopLeft(signOut).dy,
        lessThan(tester.getTopLeft(find.text('Cancel')).dy),
      );
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

    testWidgets('the stored interval and repeats show as selected',
        (tester) async {
      await tester.pumpWidget(
        _host(ReminderLevelPicker(value: _persistent, onChanged: (_) {})),
      );
      bool selected(String key) =>
          tester.widget<ChoiceButton>(find.byKey(ValueKey(key))).selected;
      expect(selected('reminder-interval-30'), isTrue);
      expect(selected('reminder-interval-15'), isFalse);
      expect(selected('reminder-repeats-5'), isTrue);
      expect(selected('reminder-repeats-3'), isFalse);
    });

    testWidgets('levels are a radio group', (tester) async {
      await tester.pumpWidget(
        _host(ReminderLevelPicker(value: _persistent, onChanged: (_) {})),
      );
      Semantics radio(String level) => tester.widget<Semantics>(
            find
                .ancestor(
                  of: find.byKey(ValueKey('reminder-level-$level')),
                  matching: find.byWidgetPredicate(
                    (w) =>
                        w is Semantics &&
                        w.properties.inMutuallyExclusiveGroup == true,
                  ),
                )
                .first,
          );
      expect(radio('persistent').properties.checked, isTrue);
      expect(radio('quiet').properties.checked, isFalse);
    });

    BannerTone toneOf(WidgetTester tester, String key) =>
        tester.widget<PillPalBanner>(find.byKey(ValueKey(key))).tone;

    Future<void> pumpCard(
      WidgetTester tester,
      ReminderStatus status, {
      String? vendor,
    }) async {
      await tester.pumpWidget(
        _host(
          const ReminderPermissionCard(),
          overrides: _overrides(status: status, vendor: vendor),
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

    testWidgets('the battery hint is a soft banner', (tester) async {
      await pumpCard(tester, const ReminderStatus(), vendor: 'xiaomi');
      expect(toneOf(tester, 'reminder-battery-hint'), BannerTone.soft);
    });

    testWidgets('the Focus hint is a soft banner', (tester) async {
      await pumpCard(tester, _noTimeSensitive);
      expect(toneOf(tester, 'reminder-time-sensitive-hint'), BannerTone.soft);
    });
  });

  group('dialogs', () {
    testWidgets('sign-out names the pending changes and can sync first',
        (tester) async {
      var synced = 0;
      await tester.pumpWidget(
        _host(
          // SyncSection watches the pending count, as on the real screen.
          const Column(children: [SyncSection(), SignOutButton()]),
          overrides: [
            ..._overrides(),
            pendingChangesProvider.overrideWith((ref) => Stream.value(2)),
            syncTriggerProvider.overrideWithValue(() async => synced++),
          ],
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('sign-out')));
      await tester.pumpAndSettle();
      expect(
        find.text(AppLocalizationsEn().signOutPendingBody(2)),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('sign-out-sync-first')));
      await tester.pumpAndSettle();
      expect(synced, 1);
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(find.byKey(const Key('sign-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(synced, 1);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('removal returns the choice, cancel returns null',
        (tester) async {
      RemovalChoice? result;
      var asked = 0;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              key: const Key('ask'),
              onPressed: () async {
                result = await askRemoval(
                  context,
                  title: 't',
                  plainBody: 'plain',
                  historyBody: 'history',
                  hasHistory: true,
                  canFinish: true,
                );
                asked++;
              },
              child: const Text('ask'),
            ),
          ),
        ),
      );
      Future<void> ask(Key button) async {
        await tester.tap(find.byKey(const Key('ask')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(button));
        await tester.pumpAndSettle();
      }

      await ask(const Key('removal-cancel'));
      expect(result, isNull);
      expect(asked, 1);
      await ask(const Key('confirm-finish'));
      expect(result, RemovalChoice.finish);
      await ask(const Key('confirm-delete'));
      expect(result, RemovalChoice.delete);
    });

    testWidgets('refill saves the typed count, cancel saves nothing',
        (tester) async {
      final saved = <String>[];
      await tester.pumpWidget(
        _host(
          Consumer(
            builder: (context, ref, _) => TextButton(
              key: const Key('refill'),
              onPressed: () => showRefillDialog(context, ref, 'med-1'),
              child: const Text('refill'),
            ),
          ),
          overrides: [
            ..._overrides(),
            stockActionsProvider.overrideWithValue(_RecordingStock(saved)),
          ],
        ),
      );
      await tester.tap(find.byKey(const Key('refill')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);

      await tester.tap(find.byKey(const Key('refill')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('refill-count')), '12,5');
      await tester.tap(find.byKey(const Key('refill-save')));
      await tester.pumpAndSettle();
      expect(saved, ['med-1:12.5']);
    });
  });

  testWidgets('ChoiceButton is a stadium', (tester) async {
    await tester.pumpWidget(
      _host(ChoiceButton(label: 'x', selected: false, onTap: () {})),
    );
    final material = tester.widget<Material>(
      find.descendant(
        of: find.byType(ChoiceButton),
        matching: find.byType(Material),
      ),
    );
    expect(material.shape, isA<StadiumBorder>());
  });
}
