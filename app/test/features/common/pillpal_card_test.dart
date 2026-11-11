import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/common/pillpal_card.dart';
import 'package:pillpal/src/theme/radius.dart';
import 'package:pillpal/src/theme/shadows.dart';
import 'package:pillpal/src/theme/sizes.dart';
import 'package:pillpal/src/theme/spacing.dart';

import 'common_test_host.dart';

const _key = Key('card');

Widget _card() => const SizedBox(
      width: 300,
      child: PillPalCard(key: _key, child: Text('Magnesium')),
    );

DecoratedBox _shadowBox(WidgetTester tester) => tester.widget<DecoratedBox>(
      find
          .descendant(of: find.byKey(_key), matching: find.byType(DecoratedBox))
          .first,
    );

Material _surface(WidgetTester tester) => tester.widget<Material>(
      find
          .descendant(of: find.byKey(_key), matching: find.byType(Material))
          .first,
    );

void main() {
  testWidgets('is a surface card of radius 20', (tester) async {
    await pumpThemed(tester, _card());
    expect(_surface(tester).color, paletteOf().surface);
    expect(
      _surface(tester).shape,
      const RoundedRectangleBorder(borderRadius: PillPalRadius.card),
    );
  });

  testWidgets('pads its child by 16', (tester) async {
    await pumpThemed(tester, _card());
    final card = tester.getRect(find.byKey(_key));
    final text = tester.getRect(find.text('Magnesium'));
    expect(text.left - card.left, PillPalSpacing.lg);
    expect(text.top - card.top, PillPalSpacing.lg);
  });

  testWidgets('light draws elevation level 1', (tester) async {
    await pumpThemed(tester, _card());
    final decoration = _shadowBox(tester).decoration as BoxDecoration;
    expect(decoration.boxShadow, PillPalShadows.level1);
    expect(decoration.borderRadius, PillPalRadius.card);
  });

  testWidgets('dark draws no shadow and steps up in lightness', (tester) async {
    await pumpThemed(tester, _card(), brightness: Brightness.dark);
    final decoration = _shadowBox(tester).decoration as BoxDecoration;
    expect(decoration.boxShadow, isEmpty);
    expect(
        _surface(tester).color, paletteOf(brightness: Brightness.dark).surface);
  });

  testWidgets('takes a custom padding', (tester) async {
    await pumpThemed(
      tester,
      const SizedBox(
        width: 300,
        child: PillPalCard(
          key: _key,
          padding: EdgeInsets.zero,
          child: Text('Magnesium'),
        ),
      ),
    );
    expect(
      tester.getTopLeft(find.text('Magnesium')),
      tester.getTopLeft(find.byKey(_key)),
    );
  });

  testWidgets('rows are separated by hairline border dividers', (tester) async {
    await pumpThemed(tester, const SizedBox(width: 300, child: _RowsCard()));
    final dividers = tester.widgetList<Divider>(find.byType(Divider)).toList();
    expect(dividers, hasLength(2));
    expect(dividers.first.color, paletteOf().border);
    expect(dividers.first.thickness, PillPalSizes.hairline);
  });
}

class _RowsCard extends StatelessWidget {
  const _RowsCard();

  @override
  Widget build(BuildContext context) => PillPalCard.rows(
        key: _key,
        rows: const [Text('a'), Text('b'), Text('c')],
      );
}
