import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/common/stacked_buttons.dart';
import 'package:pillpal/src/theme/sizes.dart';

import '../../support/ui_matrix.dart';
import 'common_test_host.dart';

const _first = Key('first');
const _second = Key('second');

Widget _pair({String first = 'Accept', String second = 'Not now'}) =>
    StackedButtons(
      children: [
        FilledButton(key: _first, onPressed: () {}, child: Text(first)),
        OutlinedButton(key: _second, onPressed: () {}, child: Text(second)),
      ],
    );

void main() {
  testWidgets('stacks the buttons, each as wide as the column', (tester) async {
    await pumpThemed(tester, SizedBox(width: 300, child: _pair()));
    final first = tester.getRect(find.byKey(_first));
    final second = tester.getRect(find.byKey(_second));
    expect(first.width, 300);
    expect(second.width, 300);
    expect(second.top, greaterThanOrEqualTo(first.bottom));
  });

  testWidgets('keeps the order of the children', (tester) async {
    await pumpThemed(tester, SizedBox(width: 300, child: _pair()));
    expect(
      tester.getTopLeft(find.byKey(_first)).dy,
      lessThan(tester.getTopLeft(find.byKey(_second)).dy),
    );
  });

  testWidgets('wraps a long label and grows to at least 56 at large scale',
      (tester) async {
    await pumpThemed(
      tester,
      SizedBox(
        width: 280,
        child: _pair(
          first: 'Принять приглашение и открыть доступ',
          second: 'Не сейчас, вернуться позже',
        ),
      ),
      locale: const Locale('ru'),
      scale: 2,
      size: const Size(320, 568),
    );
    expect(tester.takeException(), isNull);
    for (final key in [_first, _second]) {
      final rect = tester.getRect(find.byKey(key));
      expect(rect.width, 280);
      expect(rect.height, greaterThanOrEqualTo(PillPalSizes.stackedButtonMin));
    }
  });

  testWidgets('stays at the button height below the compact scale',
      (tester) async {
    await pumpThemed(tester, SizedBox(width: 300, child: _pair()));
    expect(
      tester.getSize(find.byKey(_first)).height,
      PillPalSizes.buttonHeight,
    );
  });

  testWidgets('holds in the whole matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => SingleChildScrollView(
        child: SizedBox(
          width: MediaQuery.sizeOf(context).width,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _pair(
              first: 'Принять приглашение и открыть доступ',
              second: 'Не сейчас, вернуться позже',
            ),
          ),
        ),
      ),
      expectTouchTargets: true,
      expectContrast: true,
    );
  });
}
