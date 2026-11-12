import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/common/choice_button.dart';
import 'package:pillpal/src/features/common/choice_group.dart';
import 'package:pillpal/src/localization_delegates.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';

import '../support/ui_matrix.dart';

// The choice group (chips) in the «Забота» look (redesign R2b).

Widget _host(Widget child) {
  return MaterialApp(
    theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
    localizationsDelegates: pillPalLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
  );
}

void main() {
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

    testWidgets('the selected chip shows a check icon, not colour alone',
        (tester) async {
      await tester.pumpWidget(
        _host(
          ChoiceGroup<String>(
            selected: 'b',
            onSelected: (_) {},
            keyOf: (value) => ValueKey('opt-$value'),
            options: const {'a': 'A', 'b': 'B'},
          ),
        ),
      );

      Finder check(String value) => find.descendant(
            of: find.byKey(ValueKey('opt-$value')),
            matching: find.byIcon(Icons.check),
          );
      expect(check('b'), findsOneWidget);
      expect(check('a'), findsNothing);
    });

    testWidgets('chips are stadiums; selected is `selected`, off has a border',
        (tester) async {
      await tester.pumpWidget(
        _host(
          ChoiceGroup<String>(
            selected: 'b',
            onSelected: (_) {},
            keyOf: (value) => ValueKey('opt-$value'),
            options: const {'a': 'A', 'b': 'B'},
          ),
        ),
      );

      Material material(String value) => tester.widget<Material>(
            find
                .descendant(
                  of: find.byKey(ValueKey('opt-$value')),
                  matching: find.byType(Material),
                )
                .first,
          );
      const palette = PillPalPalette.light;
      final on = material('b');
      final off = material('a');
      expect(on.color, palette.selected);
      expect(off.color, palette.surface);
      expect(on.shape, isA<StadiumBorder>());
      expect((off.shape! as StadiumBorder).side.color, palette.border);
      expect((on.shape! as StadiumBorder).side, BorderSide.none);
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(const ValueKey('opt-b')),
                matching: find.text('B'),
              ),
            )
            .style
            ?.color,
        palette.onActionSoft,
      );
    });

    testWidgets('a 44 px weekday disc keeps its label on one line at x2',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
          builder: (context, app) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: app!,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: ChoiceGroup<int>.multi(
                selectedValues: const {1},
                onSelected: (_) {},
                itemWidth: PillPalSizes.touchTarget,
                keyOf: (value) => ValueKey('day-$value'),
                options: const {1: 'Пн', 2: 'Вт'},
              ),
            ),
          ),
        ),
      );

      final label = tester.getSize(find.text('Пн'));
      final style = tester.widget<Text>(find.text('Пн')).style;
      final scaled = (style?.fontSize ?? 0) * 2;
      expect(label.height, lessThan(scaled * 1.6), reason: 'one line');
    });

    testWidgets('a custom selected colour is a solid chip without a check',
        (tester) async {
      await tester.pumpWidget(
        _host(
          ChoiceGroup<int>.multi(
            selectedValues: const {1},
            onSelected: (_) {},
            selectedColor: PillPalPalette.light.action,
            keyOf: (value) => ValueKey('day-$value'),
            options: const {1: 'M', 2: 'T'},
          ),
        ),
      );

      expect(find.byIcon(Icons.check), findsNothing);
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(const ValueKey('day-1')),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color, PillPalPalette.light.action);
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
