import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/common/status_disc.dart';
import 'package:pillpal/src/features/common/status_kind.dart';
import 'package:pillpal/src/theme/sizes.dart';

import '../../support/ui_matrix.dart';
import 'common_test_host.dart';

Color? _fill(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(
      of: find.byType(StatusDisc),
      matching: find.byType(DecoratedBox),
    ),
  );
  return (box.decoration as ShapeDecoration).color;
}

void main() {
  testWidgets('is 40 in normal mode and soft', (tester) async {
    await pumpThemed(tester, const StatusDisc(StatusKind.taken));
    final p = paletteOf();
    expect(
      tester.getSize(find.byType(StatusDisc)),
      const Size.square(PillPalSizes.statusDisc),
    );
    expect(_fill(tester), p.takenSoft);
    expect(tester.widget<Icon>(find.byIcon(Icons.check)).color, p.onTakenSoft);
  });

  testWidgets('is 52 and solid in senior mode', (tester) async {
    await pumpThemed(
      tester,
      const StatusDisc(StatusKind.missed),
      senior: true,
      brightness: Brightness.dark,
    );
    final p = paletteOf(brightness: Brightness.dark, senior: true);
    expect(
      tester.getSize(find.byType(StatusDisc)),
      const Size.square(PillPalSizes.statusDiscSenior),
    );
    expect(_fill(tester), p.missed);
    expect(_fill(tester), isNot(p.danger));
    final icon = statusStyle(StatusKind.missed, p).icon;
    expect(tester.widget<Icon>(find.byIcon(icon)).color, p.onMissed);
  });

  testWidgets('forwards its key and announces the word', (tester) async {
    final handle = tester.ensureSemantics();
    const key = Key('dose-missed-s1/2026-11-10T08:00');
    await pumpThemed(tester, const StatusDisc(StatusKind.missed, key: key));
    expect(tester.widget(find.byKey(key)), isA<StatusDisc>());
    expect(find.bySemanticsLabel('Missed'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('every status in the whole matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => Wrap(
        children: [for (final kind in StatusKind.values) StatusDisc(kind)],
      ),
      expectTouchTargets: true,
      expectContrast: true,
    );
  });
}
