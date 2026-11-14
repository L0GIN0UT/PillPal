import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/common/banner_tone.dart';
import 'package:pillpal/src/features/common/compact_rows.dart';
import 'package:pillpal/src/features/common/list_row.dart';
import 'package:pillpal/src/features/common/pillpal_banner.dart';
import 'package:pillpal/src/features/common/pillpal_card.dart';
import 'package:pillpal/src/features/family/profile_context.dart';
import 'package:pillpal/src/features/reminders/reminder_level_picker.dart';
import 'package:pillpal/src/features/reminders/reminder_permission_card.dart';
import 'package:pillpal/src/features/settings/settings_screen.dart';
import 'package:pillpal/src/localization_delegates.dart';
import 'package:pillpal/src/reminders/reminder_service.dart';
import 'package:pillpal/src/theme/spacing.dart';

import '../support/settings_fixtures.dart';
import '../support/ui_matrix.dart';

// Settings (boards B2-Settings, B2-SettingsData) in the whole UI matrix, and
// the rules of the redesign: an account card, four grouped cards, the theme
// as a segmented control that gives way to a radio list when a Russian label
// would wrap to three lines (B2-README 9), permission banners by tone.

/// A tall screen: the list builds all of it at once.
const double _tall = 12000;

Widget _screen({
  ReminderStatus status = const ReminderStatus(),
  Object? meFailure,
  List<Override> extra = const [],
}) =>
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        ...settingsOverrides(status: status, meFailure: meFailure),
        ...extra,
      ],
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

/// The control of an appearance row keeps the card's inner padding below it:
/// its bottom edge sits at least [PillPalSpacing.lg] above the card's.
void _expectInsetFromCard(WidgetTester tester, String key) {
  final control = tester.getBottomLeft(find.byKey(Key(key))).dy;
  final card = find.ancestor(
    of: find.byKey(Key(key)),
    matching: find.byType(PillPalCard),
  );
  final cardBottom = tester.getBottomLeft(card.first).dy;
  expect(
    cardBottom - control,
    greaterThanOrEqualTo(PillPalSpacing.lg),
    reason: '$key sits flush against the card edge',
  );
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
          expect(
            find.byKey(const Key('settings-change-password')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('delete-account')), findsOneWidget);
          expect(find.byKey(const Key('settings-reports')), findsOneWidget);
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
          localizationsDelegates: pillPalLocalizationsDelegates,
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

  group('account card', () {
    Future<void> pump(
      WidgetTester tester, {
      Object? meFailure,
      List<Override> extra = const [],
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, _tall);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: pillPalLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: _screen(meFailure: meFailure, extra: extra),
        ),
      );
      await _settle(tester);
    }

    for (final (name, failure) in <(String, Object)>[
      ('a network error', const ApiException(ApiException.networkError, 0)),
      ('a 401', const ApiException('unauthorized', 401)),
      ('a malformed body', const FormatException('bad')),
    ]) {
      testWidgets('$name leaves the card saying "Вы вошли"', (tester) async {
        await pump(tester, meFailure: failure);
        expect(tester.takeException(), isNull);
        expect(find.text('Вы вошли'), findsOneWidget);
        expect(find.text(settingsFixtureEmail), findsNothing);
        // The rest of the screen works.
        expect(find.byKey(const Key('sign-out')), findsOneWidget);
      });
    }

    testWidgets('a managed profile selected elsewhere: still the own account',
        (tester) async {
      await pump(
        tester,
        extra: [selectedProfileIdProvider.overrideWith(_WardSelected.new)],
      );
      expect(find.text(settingsFixtureEmail), findsOneWidget);
    });

    testWidgets('«Ваше имя» opens the account group with the stored name',
        (tester) async {
      await pump(tester);
      final row = find.byKey(const Key('settings-own-name'));
      expect(
        find.descendant(of: row, matching: find.text('Ваше имя')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text(settingsFixtureName)),
        findsOneWidget,
      );
      // First in the account group, above the password and the sign-out.
      final password = find.byKey(const Key('settings-change-password'));
      expect(
        tester.getTopLeft(row).dy,
        lessThan(tester.getTopLeft(password).dy),
      );
    });

    testWidgets('the e-mail takes two lines at most, whole in semantics',
        (tester) async {
      await pump(tester);
      final title = tester.widget<Text>(
        find.byKey(const Key('settings-account-title')),
      );
      expect(title.maxLines, 2);
      expect(title.overflow, TextOverflow.ellipsis);
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp(settingsFixtureEmail)), findsWidgets);
      handle.dispose();
    });
  });

  group('a long single-word name at 280 dp', () {
    const long = 'Александрааааааааааа'; // 20 code points, one word

    Future<bool> narrowAfter(
      WidgetTester tester,
      Stream<ProfileRow?> self,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(280, _tall);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: pillPalLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProviderScope(
            key: UniqueKey(),
            overrides: settingsOverrides(self: self),
            child: const SettingsScreen(),
          ),
        ),
      );
      await _settle(tester);
      return CompactRows.of(
        tester.element(find.byKey(const Key('settings-own-name'))),
      );
    }

    testWidgets('a rename re-decides the narrow layout of the account card',
        (tester) async {
      final fresh = await narrowAfter(
        tester,
        Stream.value(settingsFixtureSelf.copyWith(displayName: long)),
      );

      final renames = StreamController<ProfileRow?>();
      addTearDown(renames.close);
      renames.add(settingsFixtureSelf.copyWith(displayName: 'Ян'));
      await narrowAfter(tester, renames.stream);
      renames.add(settingsFixtureSelf.copyWith(displayName: long));
      await _settle(tester);

      final row = find.byKey(const Key('settings-own-name'));
      expect(
          find.descendant(of: row, matching: find.text(long)), findsOneWidget);
      expect(CompactRows.of(tester.element(row)), fresh);
      // The whole card agrees.
      expect(
        CompactRows.of(tester.element(find.byKey(const Key('sign-out')))),
        fresh,
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the last control of a card keeps the card padding below it',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(),
      sizes: const [Size(360, _tall), Size(320, _tall)],
      check: (tester, cell) async {
        await _settle(tester);
        // The language control is the last row of the appearance card.
        _expectInsetFromCard(tester, 'settings-language');
        // The reminder-level block keeps the card padding below it, before
        // the next row (hide names).
        final picker = tester.getBottomLeft(find.byType(ReminderLevelPicker));
        final next =
            tester.getTopLeft(find.byKey(const Key('reminder-hide-names')));
        expect(
          next.dy - picker.dy,
          greaterThanOrEqualTo(PillPalSpacing.lg),
        );
      },
    );
  });
}

class _WardSelected extends SelectedProfile {
  @override
  String? build() => 'ward-1';
}
