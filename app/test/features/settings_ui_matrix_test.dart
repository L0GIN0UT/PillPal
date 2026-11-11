import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/common/banner_tone.dart';
import 'package:pillpal/src/features/common/list_row.dart';
import 'package:pillpal/src/features/common/pillpal_banner.dart';
import 'package:pillpal/src/features/common/pillpal_card.dart';
import 'package:pillpal/src/features/reminders/reminder_permission_card.dart';
import 'package:pillpal/src/features/settings/settings_screen.dart';
import 'package:pillpal/src/reminders/reminder_service.dart';

import '../support/settings_fixtures.dart';
import '../support/ui_matrix.dart';

// Settings (boards B2-Settings, B2-SettingsData) in the whole UI matrix, and
// the rules of the redesign: an account card, four grouped cards, the theme
// as a segmented control that gives way to a radio list when a Russian label
// would wrap to three lines (B2-README 9), permission banners by tone.

/// A tall screen: the list builds all of it at once.
const double _tall = 9000;

Widget _screen({ReminderStatus status = const ReminderStatus()}) =>
    ProviderScope(
      key: UniqueKey(),
      overrides: settingsOverrides(status: status),
      child: Builder(
        builder: (context) => SizedBox(
          height: MediaQuery.sizeOf(context).height,
          width: MediaQuery.sizeOf(context).width,
          child: const SettingsScreen(),
        ),
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

double _top(WidgetTester tester, String key) =>
    tester.getTopLeft(find.byKey(Key(key))).dy;

void main() {
  group('matrix', () {
    testWidgets('SettingsScreen', (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => _screen(),
        sizes: const [Size(360, _tall), Size(320, _tall)],
        check: (tester, cell) async {
          await _settle(tester);
          for (final group in ['appearance', 'reminders', 'data', 'account']) {
            expect(find.byKey(Key('settings-group-$group')), findsOneWidget);
          }
          expect(find.text(settingsFixtureEmail), findsOneWidget);
          expect(find.byKey(const Key('sign-out')), findsOneWidget);
          expect(find.byKey(const Key('delete-account')), findsOneWidget);
          expect(
            find.byKey(const Key('settings-catalog-sources')),
            findsOneWidget,
          );
          expectTouchTargetsOf(tester, cell);

          // The theme control: a segmented track, or the radio list when a
          // label would wrap to three lines (RU x2.0 at 320, B2-README 9).
          final radio = find.descendant(
            of: find.byKey(const Key('settings-theme')),
            matching: find.byKey(const Key('segmented-radio-list')),
          );
          if (cell.locale.languageCode == 'ru' &&
              cell.scale == 2.0 &&
              cell.size.width == 320) {
            expect(radio, findsOneWidget, reason: cell.label);
          }
          // The test font draws every letter 1 em wide, so the track cannot
          // be asserted: the control is there, in one form or the other.
          final track = find.descendant(
            of: find.byKey(const Key('settings-theme')),
            matching: find.byType(SegmentedButton<ThemeMode>),
          );
          expect(
            radio.evaluate().length + track.evaluate().length,
            1,
            reason: cell.label,
          );
          // Contrast of the whole screen once per mode (pixels are slow).
          if (cell.scale == 1.0 && cell.size.width == 360) {
            await expectContrastOf(tester, cell);
          }
        },
      );
    });
  });

  group('layout', () {
    testWidgets('four groups, each a card with its own header', (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => _screen(),
        scales: const [1.0],
        sizes: const [Size(360, _tall)],
        check: (tester, cell) async {
          if (cell.senior || cell.locale.languageCode != 'en') {
            return;
          }
          await _settle(tester);
          final order = [
            'settings-group-appearance',
            'settings-theme',
            'settings-group-reminders',
            'settings-group-data',
            'settings-group-account',
            'sign-out',
            'delete-account',
          ];
          for (var i = 1; i < order.length; i++) {
            expect(
              _top(tester, order[i - 1]),
              lessThan(_top(tester, order[i])),
              reason: '${order[i - 1]} above ${order[i]}',
            );
          }
          for (final key in ['sign-out', 'delete-account', 'settings-theme']) {
            expect(
              find.ancestor(
                of: find.byKey(Key(key)),
                matching: find.byType(PillPalCard),
              ),
              findsOneWidget,
              reason: key,
            );
          }
        },
      );
    });

    testWidgets('only the deletion is danger, not the sign-out',
        (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => _screen(),
        scales: const [1.0],
        sizes: const [Size(360, _tall)],
        check: (tester, cell) async {
          if (cell.senior || cell.locale.languageCode != 'en') {
            return;
          }
          await _settle(tester);
          bool destructive(String key) =>
              tester.widget<PillPalListRow>(find.byKey(Key(key))).destructive;
          expect(destructive('delete-account'), isTrue);
          expect(destructive('sign-out'), isFalse);
        },
      );
    });
  });

  group('permission card in the reminders group', () {
    BannerTone toneOf(WidgetTester tester, String key) =>
        tester.widget<PillPalBanner>(find.byKey(ValueKey(key))).tone;

    Future<void> pumpSettings(
      WidgetTester tester,
      ReminderStatus status,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, _tall);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: _screen(status: status),
        ),
      );
      await _settle(tester);
    }

    testWidgets('blocking: a danger banner below the group header',
        (tester) async {
      await pumpSettings(tester, noNotificationsStatus);
      expect(
        toneOf(tester, 'reminder-permission-notifications'),
        BannerTone.danger,
      );
      expect(
        tester.getTopLeft(find.byKey(const Key('settings-group-reminders'))).dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('reminder-permission-notifications')),
              )
              .dy,
        ),
      );
    });

    testWidgets('hints: soft banners', (tester) async {
      await pumpSettings(tester, noExactAlarmsStatus);
      expect(toneOf(tester, 'reminder-permission-exact'), BannerTone.soft);
      await pumpSettings(tester, noTimeSensitiveStatus);
      expect(toneOf(tester, 'reminder-time-sensitive-hint'), BannerTone.soft);
    });

    testWidgets('nothing to say: no banner', (tester) async {
      await pumpSettings(tester, const ReminderStatus());
      expect(find.byType(ReminderPermissionCard), findsOneWidget);
      expect(find.byType(PillPalBanner), findsNothing);
    });
  });
}
