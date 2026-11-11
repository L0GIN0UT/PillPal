import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/common/status_disc.dart';
import 'package:pillpal/src/features/common/status_kind.dart';
import 'package:pillpal/src/theme/motion.dart';
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

BorderSide _ring(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(
      of: find.byType(StatusDisc),
      matching: find.byType(DecoratedBox),
    ),
  );
  return ((box.decoration as ShapeDecoration).shape as CircleBorder).side;
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

void main() {
  testWidgets('a disc that changes kind eases to the new colours in base', (
    tester,
  ) async {
    final kind = ValueNotifier<StatusKind>(StatusKind.pending);
    addTearDown(kind.dispose);
    await pumpThemed(
      tester,
      ValueListenableBuilder<StatusKind>(
        valueListenable: kind,
        builder: (context, value, _) => StatusDisc(value),
      ),
    );
    final p = paletteOf();
    final before = _fill(tester);

    kind.value = StatusKind.taken;
    await tester.pump();
    await tester.pump(PillPalMotion.base ~/ 2);
    final mid = _fill(tester);
    expect(mid, isNot(before));
    expect(mid, isNot(p.takenSoft));

    await tester.pump(PillPalMotion.base);
    expect(_fill(tester), p.takenSoft);
  });

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

  testWidgets('pending ring: border in normal mode, 3:1 muted ring in senior',
      (tester) async {
    for (final brightness in Brightness.values) {
      await pumpThemed(
        tester,
        const StatusDisc(StatusKind.pending),
        brightness: brightness,
      );
      var p = paletteOf(brightness: brightness);
      var side = _ring(tester);
      expect(side.color, p.border);
      expect(side.width, PillPalSizes.fieldBorder);

      await pumpThemed(
        tester,
        const StatusDisc(StatusKind.pending),
        senior: true,
        brightness: brightness,
      );
      p = paletteOf(brightness: brightness, senior: true);
      side = _ring(tester);
      expect(side.color, p.inkMuted, reason: '$brightness');
      expect(side.width, PillPalSizes.statusRingSenior);
      expect(
          tester.widget<Icon>(find.byIcon(Icons.circle_outlined)).color, p.ink);
      expect(_contrast(side.color, p.surface), greaterThanOrEqualTo(3));
    }
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
