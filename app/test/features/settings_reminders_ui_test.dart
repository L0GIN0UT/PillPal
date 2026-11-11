import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/l10n/gen/app_localizations_en.dart';
import 'package:pillpal/src/features/auth/auth_session.dart';
import 'package:pillpal/src/features/common/banner_tone.dart';
import 'package:pillpal/src/features/common/choice_button.dart';
import 'package:pillpal/src/features/common/choice_group.dart';
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
import 'package:pillpal/src/reminders/reminder_service.dart';
import 'package:pillpal/src/reminders/reminder_settings.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../support/settings_fixtures.dart';
import '../support/ui_matrix.dart';

// Settings and reminder screens of the UI consistency pass (UI-3).

class _RecordingStock implements StockActions {
  _RecordingStock(this.saved);

  final List<String> saved;

  @override
  Future<void> setStock(String id, String count) async =>
      saved.add('$id:$count');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
    settingsOverrides(status: status, vendor: vendor);

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
          // Three segments, or the radio list when a Russian label would
          // wrap to three lines at x2.0 (B2-README `segmented`).
          for (final level in ['quiet', 'normal', 'persistent']) {
            expect(
              find.byKey(ValueKey('reminder-level-$level')),
              findsOneWidget,
            );
          }
          // Russian at x2.0 on a 320 or 360 px phone: the radio list.
          final narrowRussian =
              cell.locale.languageCode == 'ru' && cell.scale == 2.0;
          if (narrowRussian) {
            expect(
                find.byKey(const Key('segmented-radio-list')), findsOneWidget);
          }
        },
        expectTouchTargets: true,
        expectContrast: true,
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
    testWidgets('the screen lists the catalog sources row', (tester) async {
      tester.view.physicalSize = const Size(800, 6000);
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

    testWidgets('sign-out without unsent changes is a plain primary dialog',
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
      expect(fill, isNull);
      expect(find.byKey(const Key('dialog-icon')), findsNothing);
      expect(find.byKey(const Key('sign-out-cancel')), findsOneWidget);
    });

    testWidgets('sign-out with unsent changes is a danger dialog',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const Column(children: [SyncSection(), SignOutButton()]),
          overrides: [
            ..._overrides(),
            pendingChangesProvider.overrideWith((ref) => Stream.value(2)),
          ],
        ),
      );
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
      expect(find.byKey(const Key('dialog-icon')), findsOneWidget);
      expect(
        tester.getTopLeft(signOut).dy,
        lessThan(
            tester.getTopLeft(find.byKey(const Key('sign-out-cancel'))).dy),
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
