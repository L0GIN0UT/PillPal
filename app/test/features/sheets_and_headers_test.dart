import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/common/action_sheet.dart';
import 'package:pillpal/src/features/common/section_header.dart';
import 'package:pillpal/src/features/common/sheet_scaffold.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal/src/theme/spacing.dart';

import '../support/ui_matrix.dart';

// Section headers, group labels, bottom sheets and action sheets of the UI
// consistency pass, and the matrix helper they are checked with.

Widget _host(Widget child) {
  return MaterialApp(
    theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
  );
}

bool _isHeader(Widget widget) =>
    widget is Semantics && widget.properties.header == true;

void main() {
  group('pumpUiMatrix', () {
    testWidgets('visits every theme, mode, locale and scale', (tester) async {
      final cells = <String>{};
      await pumpUiMatrix(
        tester,
        (context) => const SizedBox.shrink(),
        check: (tester, cell) async => cells.add(cell.label),
      );

      expect(cells, hasLength(2 * 2 * 2 * 2 * 2));
    });

    testWidgets('fails on a layout overflow and names the cell',
        (tester) async {
      String? failure;
      try {
        await pumpUiMatrix(
          tester,
          (context) => Row(
            children: [
              for (var i = 0; i < 4; i++)
                const SizedBox(width: 120, child: Text('overflow')),
            ],
          ),
        );
      } on TestFailure catch (error) {
        failure = error.message;
      }

      expect(failure, contains('UI matrix cell "light normal'));
    });
  });

  group('SectionHeader', () {
    testWidgets('render in the whole matrix with a trailing widget',
        (tester) async {
      await pumpUiMatrix(
        tester,
        (context) {
          final l10n = AppLocalizations.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(
                l10n.reminderPermissionNotificationsTitle,
                first: true,
                trailing: const Icon(Icons.add),
              ),
            ],
          );
        },
      );
    });

    testWidgets('a section header has a top gap unless it is first',
        (tester) async {
      Future<double> top({required bool first}) async {
        await tester.pumpWidget(
          _host(SectionHeader('Title', first: first, key: const Key('h'))),
        );
        return tester.getTopLeft(find.text('Title')).dy -
            tester.getTopLeft(find.byKey(const Key('h'))).dy;
      }

      expect(await top(first: true), 0);
      expect(await top(first: false), PillPalSpacing.xxl);
    });

    testWidgets('a section header is titleMedium with 24 above, 12 below',
        (tester) async {
      await tester.pumpWidget(
        _host(const SectionHeader('Title', key: Key('h'))),
      );

      final box = tester.getRect(find.byKey(const Key('h')));
      final text = tester.getRect(find.text('Title'));
      expect(text.top - box.top, PillPalSpacing.sectionTop);
      expect(box.bottom - text.bottom, PillPalSpacing.sectionBottom);
      final style = tester.widget<Text>(find.text('Title')).style;
      expect(style?.fontFamily, PillPalFonts.display);
      expect(style?.fontSize, 18);
      expect(style?.fontWeight, FontWeight.w700);
    });

    testWidgets('a section header is a semantic header with a title key',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const SectionHeader(
            'Title',
            titleKey: Key('t'),
            trailing: Icon(Icons.add, key: Key('end')),
          ),
        ),
      );

      expect(find.byWidgetPredicate(_isHeader), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('t'))).data, 'Title');
      expect(find.byKey(const Key('end')), findsOneWidget);
    });
  });

  group('SheetScaffold and showPillPalSheet', () {
    testWidgets('open in the whole matrix; long content scrolls',
        (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => FilledButton(
          key: const Key('open'),
          onPressed: () => showPillPalSheet<void>(
            context,
            (sheet) {
              final l10n = AppLocalizations.of(sheet);
              return SheetScaffold(
                title: l10n.reminderPermissionNotificationsTitle,
                primaryAction: FilledButton(
                  key: const Key('primary'),
                  onPressed: () => Navigator.of(sheet).pop(),
                  child: Text(l10n.reminderPermissionAllow),
                ),
                children: [
                  for (var i = 0; i < 12; i++)
                    Text(l10n.reminderPermissionNotificationsBody),
                ],
              );
            },
          ),
          child: const Text('open'),
        ),
        check: (tester, cell) async {
          await tester.tap(find.byKey(const Key('open')));
          await tester.pumpAndSettle();
          expect(find.byType(SheetScaffold), findsOneWidget);
          expect(find.byWidgetPredicate(_isHeader), findsOneWidget);
          expectTouchTargetsOf(tester, cell);
          // Scrolled into view, the primary action closes the sheet.
          await tester.ensureVisible(find.byKey(const Key('primary')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('primary')));
          await tester.pumpAndSettle();
          expect(find.byType(SheetScaffold), findsNothing);
        },
      );
    });

    testWidgets('the title key, children and primary action are forwarded',
        (tester) async {
      await tester.pumpWidget(
        _host(
          SheetScaffold(
            title: 'Period',
            titleKey: const Key('sheet-title'),
            primaryAction: FilledButton(
              key: const Key('go'),
              onPressed: () {},
              child: const Text('Go'),
            ),
            children: const [Text('Body')],
          ),
        ),
      );

      expect(
        tester.widget<Text>(find.byKey(const Key('sheet-title'))).data,
        'Period',
      );
      expect(find.byKey(const Key('go')), findsOneWidget);
      expect(find.text('Body'), findsOneWidget);
    });

    testWidgets('a sheet without a title shows only its content',
        (tester) async {
      await tester.pumpWidget(
        _host(const SheetScaffold(children: [Text('Body')])),
      );

      expect(find.text('Body'), findsOneWidget);
    });

    testWidgets('the primary action stays above the keyboard', (tester) async {
      tester.view
        ..physicalSize = const Size(360, 800)
        ..devicePixelRatio = 1
        ..viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => FilledButton(
              key: const Key('open'),
              onPressed: () => showPillPalSheet<void>(
                context,
                (sheet) => SheetScaffold(
                  title: 'Title',
                  primaryAction: FilledButton(
                    key: const Key('primary'),
                    onPressed: () {},
                    child: const Text('Go'),
                  ),
                  children: const [TextField(key: Key('field'))],
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      expect(
        tester.getBottomLeft(find.byKey(const Key('primary'))).dy,
        lessThanOrEqualTo(800 - 300),
      );
    });

    testWidgets('the sheet keeps the sheet padding and a 48 % scrim',
        (tester) async {
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => FilledButton(
              key: const Key('open'),
              onPressed: () => showPillPalSheet<void>(
                context,
                (sheet) => const SheetScaffold(
                  title: 'Title',
                  children: [Text('Body', key: Key('body'))],
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byKey(const Key('body'))).dx -
            tester.getTopLeft(find.byType(SheetScaffold)).dx,
        PillPalSpacing.sheet.left,
      );
      final barrier = tester.widget<ModalBarrier>(
        find.byType(ModalBarrier).last,
      );
      expect(
        barrier.color,
        PillPalPalette.light.scrim.withValues(alpha: PillPalSizes.scrimOpacity),
      );
    });

    testWidgets('showPillPalSheet returns the popped value', (tester) async {
      String? result;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => FilledButton(
              key: const Key('open'),
              onPressed: () async => result = await showPillPalSheet<String>(
                context,
                (sheet) => FilledButton(
                  key: const Key('pick'),
                  onPressed: () => Navigator.of(sheet).pop('picked'),
                  child: const Text('Pick'),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pick')));
      await tester.pumpAndSettle();

      expect(result, 'picked');
    });
  });

  group('ActionSheet', () {
    Widget sheet(BuildContext context, List<String> taps) {
      final l10n = AppLocalizations.of(context);
      return ActionSheet(
        title: l10n.reminderPermissionNotificationsTitle,
        subtitle: l10n.reminderPermissionExactBody,
        items: [
          ActionSheetItem(
            key: const Key('item-take'),
            icon: Icons.check_circle_outline,
            title: l10n.reminderPermissionAllow,
            onTap: () => taps.add('take'),
          ),
          ActionSheetItem(
            key: const Key('item-group'),
            title: l10n.reminderTimeSensitiveBody,
            subtitle: l10n.reminderBatteryDone,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => taps.add('group'),
          ),
          ActionSheetItem(
            key: const Key('item-delete'),
            icon: Icons.delete_outline,
            title: l10n.reminderPermissionOpenSettings,
            destructive: true,
            onTap: () => taps.add('delete'),
          ),
        ],
      );
    }

    testWidgets('renders in the whole matrix; targets follow the mode',
        (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => sheet(context, <String>[]),
        expectTouchTargets: true,
      );
    });

    testWidgets('tiles and heading share the sheet side edge', (tester) async {
      await tester.pumpWidget(_host(Builder(builder: (c) => sheet(c, []))));

      expect(
        tester.getTopLeft(find.text('Allow')).dx,
        greaterThanOrEqualTo(PillPalSpacing.xl),
      );
      expect(find.byWidgetPredicate(_isHeader), findsOneWidget);
    });

    testWidgets('keys reach the tappable tile and taps run the item',
        (tester) async {
      final taps = <String>[];
      await tester.pumpWidget(_host(Builder(builder: (c) => sheet(c, taps))));

      await tester.tap(find.byKey(const Key('item-take')));
      await tester.tap(find.byKey(const Key('item-group')));
      await tester.tap(find.byKey(const Key('item-delete')));

      expect(taps, ['take', 'group', 'delete']);
      expect(
          tester.widget(find.byKey(const Key('item-take'))), isA<ListTile>());
    });

    testWidgets('a destructive item uses the danger colour', (tester) async {
      await tester.pumpWidget(
        _host(Builder(builder: (c) => sheet(c, <String>[]))),
      );

      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('item-delete')),
          matching: find.byIcon(Icons.delete_outline),
        ),
      );
      expect(icon.color, PillPalPalette.light.danger);
    });
  });
}
