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
      }, expectTouchTargets: true);
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

      final soft = await card(BannerTone.soft);
      expect(soft.color, palette.actionSoft);
      // No override: the theme's card has no border.
      expect(soft.shape, isNull);
      final info = await card(BannerTone.info);
      expect(info.color, palette.raised);
      expect(info.shape, isNull);
      final danger = await card(BannerTone.danger);
      expect(danger.color, palette.surface);
      expect(border(danger), palette.danger);
    });

    testWidgets('the icon is hidden from screen readers and capped',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPillPalTheme(brightness: Brightness.light, senior: true),
          builder: (context, app) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(3)),
            child: app!,
          ),
          home: const Scaffold(
            body: PillPalBanner(tone: BannerTone.danger, body: 'Failed'),
          ),
        ),
      );

      final icon = find.byIcon(Icons.error_outline);
      expect(
        find.ancestor(of: icon, matching: find.byType(ExcludeSemantics)),
        findsWidgets,
      );
      expect(tester.widget<Icon>(icon).size, PillPalSizes.iconSenior);
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
        expectTouchTargets: true,
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

    testWidgets('chips are as wide as their labels and share a row',
        (tester) async {
      await tester.pumpWidget(
        _host(
          ChoiceGroup<int>(
            selected: 1,
            onSelected: (_) {},
            keyOf: (value) => ValueKey('c-$value'),
            options: const {1: 'A', 2: 'B'},
          ),
        ),
      );

      final first = tester.getRect(find.byKey(const ValueKey('c-1')));
      final second = tester.getRect(find.byKey(const ValueKey('c-2')));
      expect(first.width, lessThan(100));
      expect(second.top, first.top);
      expect(second.left, greaterThan(first.right));
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

    testWidgets('the optional variant highlights nothing for null or unknown',
        (tester) async {
      Future<List<bool>> shown(String? selected) async {
        await tester.pumpWidget(
          _host(
            ChoiceGroup<String>.optional(
              selected: selected,
              onSelected: (_) {},
              keyOf: (value) => ValueKey('o-$value'),
              options: const {'a': 'A', 'b': 'B'},
            ),
          ),
        );
        return [
          for (final value in ['a', 'b'])
            tester
                .widget<ChoiceButton>(find.byKey(ValueKey('o-$value')))
                .selected,
        ];
      }

      expect(await shown('b'), [false, true]);
      expect(await shown(null), [false, false]);
      expect(await shown('gone'), [false, false]);
    });

    testWidgets('itemWidth is a minimum that never beats the touch target',
        (tester) async {
      await tester.pumpWidget(
        _host(
          ChoiceGroup<int>.multi(
            selectedValues: const {},
            onSelected: (_) {},
            itemWidth: 10,
            keyOf: (value) => ValueKey('day-$value'),
            options: const {1: 'M'},
          ),
        ),
      );

      expect(
        tester.getSize(find.byKey(const ValueKey('day-1'))).width,
        greaterThanOrEqualTo(PillPalSizes.touchTarget),
      );
    });

    testWidgets('weekday-like chips fit every cell of the matrix',
        (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => ChoiceGroup<int>.multi(
          selectedValues: const {1, 7},
          onSelected: (_) {},
          itemWidth: PillPalSizes.touchTarget,
          options: const {
            1: 'Пн',
            2: 'Вт',
            3: 'Ср',
            4: 'Чт',
            5: 'Пт',
            6: 'Сб',
            7: 'Вс',
          },
        ),
        scales: const [2.0],
        expectTouchTargets: true,
      );
    });

    testWidgets('a selected value that is not an option is a bug',
        (tester) async {
      await tester.pumpWidget(
        _host(
          ChoiceGroup<int>(
            selected: 9,
            onSelected: (_) {},
            options: const {1: 'A'},
          ),
        ),
      );

      expect(tester.takeException(), isA<AssertionError>());
    });
  });
}
