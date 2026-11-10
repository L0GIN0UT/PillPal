import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/common/banner_tone.dart';
import 'package:pillpal/src/features/common/pillpal_banner.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal/src/theme/radius.dart';

import '../support/ui_matrix.dart';

// The banner of the UI consistency pass and the «Забота» redesign (R2b).

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

    testWidgets('tones take their colours from the palette pairs',
        (tester) async {
      Future<void> show(BannerTone tone) => tester.pumpWidget(
            _host(
              PillPalBanner(
                tone: tone,
                icon: Icons.notifications_off_outlined,
                title: 'T',
                body: 'B',
                bodyKey: const Key('body'),
              ),
            ),
          );
      BoxDecoration box() => tester
          .widget<DecoratedBox>(
            find
                .descendant(
                  of: find.byType(PillPalBanner),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          )
          .decoration as BoxDecoration;
      Color? bodyColor() =>
          tester.widget<Text>(find.byKey(const Key('body'))).style?.color;
      Color? iconColor() => tester
          .widget<Icon>(find.byIcon(Icons.notifications_off_outlined))
          .color;
      const palette = PillPalPalette.light;
      final expected = {
        BannerTone.soft: (palette.actionSoft, palette.onActionSoft),
        BannerTone.info: (palette.raised, palette.ink),
        BannerTone.danger: (palette.dangerSoft, palette.onDangerSoft),
      };

      for (final entry in expected.entries) {
        await show(entry.key);
        expect(box().color, entry.value.$1, reason: '${entry.key} fill');
        expect(bodyColor(), entry.value.$2, reason: '${entry.key} text');
        expect(iconColor(), entry.value.$2, reason: '${entry.key} icon');
        // Radius 20, no border, in every tone.
        expect(box().borderRadius, PillPalRadius.card);
        expect(box().border, isNull);
      }
    });

    testWidgets('has the banner padding and a 20 px icon', (tester) async {
      await tester.pumpWidget(
        _host(
          const PillPalBanner(
            icon: Icons.inventory_2_outlined,
            title: 'T',
            body: 'B',
          ),
        ),
      );

      final padding = tester
          .widgetList<Padding>(
            find.descendant(
              of: find.byType(PillPalBanner),
              matching: find.byType(Padding),
            ),
          )
          .map((padding) => padding.padding)
          .toList();
      expect(
        padding,
        contains(
          const EdgeInsets.symmetric(
            vertical: PillPalSizes.bannerPaddingVertical,
            horizontal: PillPalSizes.bannerPaddingHorizontal,
          ),
        ),
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.inventory_2_outlined)).size,
        PillPalSizes.iconInline,
      );
    });

    testWidgets('a trailing widget sits at the end of the first row',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 300,
            child: PillPalBanner(
              body: 'Note',
              trailing: Icon(Icons.close, key: Key('end')),
            ),
          ),
        ),
      );

      expect(
        tester.getTopLeft(find.byKey(const Key('end'))).dx,
        greaterThanOrEqualTo(tester.getTopRight(find.text('Note')).dx),
      );
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
}
