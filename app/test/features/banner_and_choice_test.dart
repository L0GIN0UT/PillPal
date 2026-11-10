import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/common/banner_tone.dart';
import 'package:pillpal/src/features/common/choice_button.dart';
import 'package:pillpal/src/features/common/choice_group.dart';
import 'package:pillpal/src/features/common/pillpal_banner.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';

import '../support/ui_matrix.dart';

// The banner and the choice group of the UI consistency pass.

Widget _host(Widget child) {
  return MaterialApp(
    theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
  );
}

bool _isLiveRegion(Widget widget) =>
    widget is Semantics && widget.properties.liveRegion == true;

void main() {
  group('PillPalBanner', () {
    testWidgets('every tone renders in the whole matrix', (tester) async {
      await pumpUiMatrix(tester, (context) {
        final l10n = AppLocalizations.of(context);
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final tone in BannerTone.values)
                PillPalBanner(
                  tone: tone,
                  icon: Icons.notifications_off_outlined,
                  title: l10n.reminderPermissionNotificationsTitle,
                  body: l10n.reminderPermissionNotificationsBody,
                  actions: [
                    FilledButton(
                      onPressed: () {},
                      child: Text(l10n.reminderPermissionAllow),
                    ),
                    TextButton(
                      onPressed: () {},
                      child: Text(l10n.reminderBatteryDone),
                    ),
                  ],
                ),
              PillPalBanner(tone: BannerTone.info, body: l10n.gotIt),
              PillPalBanner(title: l10n.reminderPermissionExactTitle),
            ],
          ),
        );
      });
    });

    testWidgets('shows the body with its key and runs an action',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          PillPalBanner(
            key: const Key('banner'),
            icon: Icons.inventory_2_outlined,
            title: 'Title',
            body: 'Body',
            bodyKey: const Key('banner-body'),
            actions: [
              TextButton(
                key: const Key('act'),
                onPressed: () => taps++,
                child: const Text('Act'),
              ),
            ],
          ),
        ),
      );

      expect(find.byKey(const Key('banner')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('banner-body'))).data,
        'Body',
      );
      await tester.tap(find.byKey(const Key('act')));
      expect(taps, 1);
    });

    testWidgets('actions can sit at the end of the banner', (tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 300,
            child: PillPalBanner(
              title: 'Title',
              actionsAlignment: WrapAlignment.end,
              actions: [
                TextButton(
                  key: const Key('act'),
                  onPressed: () {},
                  child: const Text('Act'),
                ),
              ],
            ),
          ),
        ),
      );

      expect(
        tester.getTopRight(find.byKey(const Key('act'))).dx,
        greaterThan(300 / 2),
      );
    });

    testWidgets('the danger tone has an icon even when none is given',
        (tester) async {
      await tester.pumpWidget(
        _host(const PillPalBanner(tone: BannerTone.danger, body: 'Failed')),
      );

      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('tones take their colours from the palette', (tester) async {
      Future<Card> card(BannerTone tone) async {
        await tester.pumpWidget(
          _host(PillPalBanner(tone: tone, title: 'T', body: 'B')),
        );
        return tester.widget<Card>(find.byType(Card));
      }

      Color border(Card card) =>
          (card.shape! as RoundedRectangleBorder).side.color;
      const palette = PillPalPalette.light;

      expect((await card(BannerTone.soft)).color, palette.actionSoft);
      final info = await card(BannerTone.info);
      expect(info.color, palette.surface);
      expect(border(info), palette.missed);
      final danger = await card(BannerTone.danger);
      expect(danger.color, palette.surface);
      expect(border(danger), palette.danger);
    });

    testWidgets('liveRegion announces the banner to screen readers',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const PillPalBanner(
            tone: BannerTone.danger,
            body: 'Failed',
            liveRegion: true,
          ),
        ),
      );
      expect(find.byWidgetPredicate(_isLiveRegion), findsOneWidget);

      await tester.pumpWidget(_host(const PillPalBanner(body: 'Quiet')));
      expect(find.byWidgetPredicate(_isLiveRegion), findsNothing);
    });
  });

  group('ChoiceGroup', () {
    testWidgets('renders in the whole matrix; targets follow the mode',
        (tester) async {
      await pumpUiMatrix(
        tester,
        (context) {
          final l10n = AppLocalizations.of(context);
          return ChoiceGroup<int>(
            selected: 1,
            onSelected: (_) {},
            options: {
              0: l10n.reminderPermissionAllow,
              1: l10n.reminderBatteryDone,
              2: l10n.reminderPermissionOpenSettings,
              3: l10n.settingsSeniorMode,
            },
          );
        },
        check: (tester, cell) async {
          final target = cell.senior
              ? PillPalSizes.seniorButtonHeight
              : PillPalSizes.touchTarget;
          final buttons = find.byType(ChoiceButton);
          for (var i = 0; i < buttons.evaluate().length; i++) {
            final size = tester.getSize(buttons.at(i));
            expect(size.height, greaterThanOrEqualTo(target));
            expect(size.width, greaterThanOrEqualTo(target));
          }
        },
      );
    });

    testWidgets('selects, reports taps and forwards per-option keys',
        (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(
        _host(
          ChoiceGroup<String>(
            key: const Key('group'),
            selected: 'b',
            onSelected: tapped.add,
            keyOf: (value) => ValueKey('opt-$value'),
            options: const {'a': 'A', 'b': 'B'},
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('opt-a')));

      expect(tapped, ['a']);
      expect(find.byKey(const Key('group')), findsOneWidget);
      bool selected(String value) => tester
          .widget<ChoiceButton>(find.byKey(ValueKey('opt-$value')))
          .selected;
      expect([selected('a'), selected('b')], [false, true]);
    });

    testWidgets('the multi variant marks every selected value', (tester) async {
      final toggled = <int>[];
      await tester.pumpWidget(
        _host(
          ChoiceGroup<int>.multi(
            selectedValues: const {1, 3},
            onSelected: toggled.add,
            itemWidth: PillPalSizes.touchTarget,
            selectedColor: PillPalPalette.light.action,
            keyOf: (value) => ValueKey('day-$value'),
            options: const {1: 'M', 2: 'T', 3: 'W'},
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('day-2')));

      expect(toggled, [2]);
      bool selected(int day) => tester
          .widget<ChoiceButton>(find.byKey(ValueKey('day-$day')))
          .selected;
      expect([selected(1), selected(2), selected(3)], [true, false, true]);
      expect(
        tester.getSize(find.byKey(const ValueKey('day-1'))).width,
        PillPalSizes.touchTarget,
      );
    });
  });
}
