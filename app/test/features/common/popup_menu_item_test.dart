import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/common/popup_menu_item.dart';
import 'package:pillpal/src/theme/app_theme.dart';

void main() {
  for (final senior in [false, true]) {
    testWidgets('a popup item is a touch target of the mode (senior: $senior)',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme:
              buildPillPalTheme(brightness: Brightness.light, senior: senior),
          home: Scaffold(
            body: Builder(
              builder: (context) => PopupMenuButton<int>(
                key: const Key('menu'),
                itemBuilder: (context) => [
                  pillPalPopupItem(
                    context,
                    key: const Key('item'),
                    value: 1,
                    child: const Text('x'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('menu')));
      await tester.pumpAndSettle();

      final expected =
          senior ? PillPalSizes.seniorButtonHeight : PillPalSizes.touchTarget;
      expect(
        tester.getSize(find.byKey(const Key('item'))).height,
        greaterThanOrEqualTo(expected),
      );
    });
  }
}
