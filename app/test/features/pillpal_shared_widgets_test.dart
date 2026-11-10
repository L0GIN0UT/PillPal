import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/common/icon_label.dart';
import 'package:pillpal/src/features/common/info_note.dart';
import 'package:pillpal/src/features/common/pillpal_icon_button.dart';
import 'package:pillpal/src/features/common/status_message.dart';
import 'package:pillpal/src/theme/app_theme.dart';

// The shared widgets of the UI consistency pass: touch targets that follow
// the mode, icons that scale with the text, one look for notes and states.

Widget _host(Widget child, {bool senior = false, double scale = 1}) {
  return MaterialApp(
    theme: buildPillPalTheme(brightness: Brightness.light, senior: senior),
    builder: (context, app) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale),
      ),
      child: app!,
    ),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  for (final senior in [false, true]) {
    testWidgets('PillPalIconButton is a full touch target (senior $senior)',
        (tester) async {
      await tester.pumpWidget(
        _host(
          PillPalIconButton(
            key: const Key('b'),
            icon: Icons.close,
            tooltip: 'Close',
            onPressed: () {},
          ),
          senior: senior,
        ),
      );

      final size = tester.getSize(find.byKey(const Key('b')));
      final target =
          senior ? PillPalSizes.seniorButtonHeight : PillPalSizes.touchTarget;
      expect(size.width, greaterThanOrEqualTo(target));
      expect(size.height, greaterThanOrEqualTo(target));
    });
  }

  testWidgets('IconLabel and StatusMessage icons grow with the text scale',
      (tester) async {
    Future<double> iconSize(double scale) async {
      await tester.pumpWidget(
        _host(
          const Column(
            children: [
              IconLabel(icon: Icons.history, text: 'a'),
              StatusMessage(icon: Icons.wifi_off, text: 'b'),
            ],
          ),
          scale: scale,
        ),
      );
      final sizes = tester
          .widgetList<Icon>(find.byType(Icon))
          .map((icon) => icon.size!)
          .toList();
      // bodySmall (14) next to bodyMedium (15): docs/design.md type table.
      expect(sizes[0], closeTo(sizes[1] * 14 / 15, 0.01));
      return sizes[1];
    }

    final normal = await iconSize(1);
    final large = await iconSize(2);

    expect(large, closeTo(normal * 2, 0.01));
  });

  testWidgets('InfoNote shows its trailing widget at the end', (tester) async {
    await tester.pumpWidget(
      _host(
        const InfoNote(
          text: 'Note',
          trailing: Icon(Icons.close, key: Key('end')),
        ),
      ),
    );

    expect(find.text('Note'), findsOneWidget);
    expect(find.byKey(const Key('end')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('end'))).dx,
      greaterThanOrEqualTo(tester.getTopRight(find.text('Note')).dx),
    );
  });
}
