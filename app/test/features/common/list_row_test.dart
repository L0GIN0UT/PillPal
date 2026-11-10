import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/common/list_row.dart';
import 'package:pillpal/src/theme/sizes.dart';

import '../../support/ui_matrix.dart';
import 'common_test_host.dart';

const _tileIcon = Icons.notifications_none;

Widget _row({
  String title = 'Sound',
  String? subtitle,
  Widget? trailing,
  VoidCallback? onTap,
}) =>
    SizedBox(
      width: double.infinity,
      child: PillPalListRow(
        key: const Key('row'),
        title: title,
        subtitle: subtitle,
        leadingIcon: _tileIcon,
        trailing: trailing,
        onTap: onTap ?? () {},
      ),
    );

void main() {
  testWidgets('shows the tile, the title and the chevron at scale 1',
      (tester) async {
    await pumpThemed(tester, _row());
    expect(find.byIcon(_tileIcon), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.text('Sound'), findsOneWidget);
  });

  testWidgets('is at least 60 high, 76 in senior mode', (tester) async {
    await pumpThemed(tester, _row());
    expect(
      tester.getSize(find.byKey(const Key('row'))).height,
      PillPalSizes.listRowMin,
    );
    await pumpThemed(tester, _row(), senior: true);
    expect(
      tester.getSize(find.byKey(const Key('row'))).height,
      PillPalSizes.listRowMinSenior,
    );
  });

  testWidgets('the tile is a 40 disc', (tester) async {
    await pumpThemed(tester, _row());
    final disc = find.ancestor(
      of: find.byIcon(_tileIcon),
      matching: find.byType(DecoratedBox),
    );
    expect(
        tester.getSize(disc.first), const Size.square(PillPalSizes.avatarSm));
  });

  testWidgets('hides the tile and the chevron from the compact scale',
      (tester) async {
    await pumpThemed(tester, _row(), scale: PillPalSizes.compactScale);
    expect(find.byIcon(_tileIcon), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.text('Sound'), findsOneWidget);
  });

  testWidgets('keeps both just below the compact scale', (tester) async {
    await pumpThemed(tester, _row(), scale: 1.5);
    expect(find.byIcon(_tileIcon), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('the whole row is tappable, also without its tile',
      (tester) async {
    var taps = 0;
    await pumpThemed(
      tester,
      _row(onTap: () => taps++),
      scale: 2,
    );
    await tester.tap(find.text('Sound'));
    expect(taps, 1);
  });

  testWidgets('the trailing widget sits at the top when the text wraps',
      (tester) async {
    await pumpThemed(
      tester,
      _row(
        title: 'Reminder level for every medication of the whole family',
        subtitle: 'Applies to all of them at once',
        trailing: const Icon(Icons.check_circle_outline, key: Key('trailing')),
      ),
      scale: 1.5,
      size: const Size(320, 568),
    );
    final row = tester.getRect(find.byKey(const Key('row')));
    final trailing = tester.getCenter(find.byKey(const Key('trailing')));
    expect(row.height, greaterThan(PillPalSizes.listRowMin * 2));
    expect(trailing.dy, lessThan(row.top + row.height / 2));
  });

  testWidgets('a long trailing text goes under the text from the compact scale',
      (tester) async {
    await pumpThemed(
      tester,
      _row(
        title: 'Напоминания',
        subtitle: 'Для всех лекарств',
        trailing: const Text('Настойчивое со звуком', key: Key('trailing')),
      ),
      locale: const Locale('ru'),
      scale: 2,
      size: const Size(320, 568),
    );
    expect(tester.takeException(), isNull);
    final title = tester.getRect(find.text('Напоминания'));
    final trailing = tester.getRect(find.byKey(const Key('trailing')));
    expect(trailing.top, greaterThanOrEqualTo(title.bottom));
    expect(trailing.right, lessThanOrEqualTo(320));
  });

  testWidgets('a tappable row is a button for screen readers', (tester) async {
    await pumpThemed(tester, _row());
    bool isButton(Widget w) => w is Semantics && w.properties.button == true;
    expect(
      find.descendant(
        of: find.byKey(const Key('row')),
        matching: find.byWidgetPredicate(isButton),
      ),
      findsOneWidget,
    );
    await pumpThemed(tester, const PillPalListRow(key: Key('row'), title: 'A'));
    expect(
      find.descendant(
        of: find.byKey(const Key('row')),
        matching: find.byWidgetPredicate(isButton),
      ),
      findsNothing,
    );
  });

  testWidgets('the trailing widget is centred while the text is one line',
      (tester) async {
    await pumpThemed(
      tester,
      _row(
          trailing:
              const Icon(Icons.check_circle_outline, key: Key('trailing'))),
    );
    final row = tester.getRect(find.byKey(const Key('row')));
    expect(
      tester.getCenter(find.byKey(const Key('trailing'))).dy,
      closeTo(row.center.dy, 1),
    );
  });

  testWidgets('every combination holds in the whole matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => SingleChildScrollView(
        child: SizedBox(
          width: MediaQuery.sizeOf(context).width,
          child: Column(
            children: [
              _row(),
              _row(
                title: 'Напоминания о приёме лекарств для всей семьи',
                subtitle: 'Одинаково для всех лекарств',
                trailing: const Icon(Icons.check_circle_outline),
              ),
            ],
          ),
        ),
      ),
      expectTouchTargets: true,
      expectContrast: true,
    );
  });
}
