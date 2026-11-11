import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/common/banner_tone.dart';
import 'package:pillpal/src/features/common/icon_label.dart';
import 'package:pillpal/src/features/common/pillpal_banner.dart';
import 'package:pillpal/src/features/common/pillpal_icon_button.dart';
import 'package:pillpal/src/features/common/status_message.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';

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

final _inner = find.descendant(
  of: find.byKey(const Key('b')),
  matching: find.byType(IconButton),
);

void main() {
  for (final senior in [false, true]) {
    testWidgets(
        'PillPalIconButton is a 48 circle, 64 in senior (senior $senior)',
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
          senior ? PillPalSizes.seniorButtonHeight : PillPalSizes.avatarMd;
      expect(size, Size(target, target));
      final shape =
          tester.widget<IconButton>(_inner).style?.shape?.resolve(const {});
      expect(shape, isA<CircleBorder>());
      expect((shape! as CircleBorder).side, BorderSide.none);
    });
  }

  testWidgets('the secondary PillPalIconButton has a border ring',
      (tester) async {
    await tester.pumpWidget(
      _host(
        PillPalIconButton.secondary(
          key: const Key('b'),
          icon: Icons.close,
          tooltip: 'Close',
          onPressed: () {},
        ),
      ),
    );

    final shape =
        tester.widget<IconButton>(_inner).style?.shape?.resolve(const {});
    expect(shape, isA<CircleBorder>());
    expect(
      (shape! as CircleBorder).side,
      BorderSide(
        color: PillPalPalette.light.border,
        width: PillPalSizes.fieldBorder,
      ),
    );
    expect(tester.getSize(find.byKey(const Key('b'))), const Size(48, 48));
  });

  testWidgets('StatusMessage uses the muted ink for its icon', (tester) async {
    await tester.pumpWidget(
      _host(const StatusMessage(icon: Icons.wifi_off, text: 'Offline')),
    );

    expect(
      tester.widget<Icon>(find.byIcon(Icons.wifi_off)).color,
      PillPalPalette.light.inkMuted,
    );
  });

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

  testWidgets('an info banner shows its trailing widget at the end',
      (tester) async {
    await tester.pumpWidget(
      _host(
        const PillPalBanner(
          tone: BannerTone.info,
          body: 'Note',
          trailing: Icon(Icons.close, key: Key('end')),
        ),
      ),
    );

    expect(find.text('Note'), findsOneWidget);
    expect(find.byKey(const Key('end')), findsOneWidget);
    // The info banner: raised fill, ink text.
    expect(find.byType(PillPalBanner), findsOneWidget);
    expect(
      tester.widget<PillPalBanner>(find.byType(PillPalBanner)).tone,
      BannerTone.info,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('end'))).dx,
      greaterThanOrEqualTo(tester.getTopRight(find.text('Note')).dx),
    );
  });
}
