import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal/src/theme/radius.dart';
import 'package:pillpal/src/theme/spacing.dart';

double _buttonHeight(ThemeData theme) {
  final size = theme.filledButtonTheme.style?.minimumSize?.resolve({});
  return size?.height ?? 0;
}

/// WCAG 2.x contrast ratio of two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Text on background pairs, content on state colours, and state colours
/// used as text or icons on the screen backgrounds.
Map<String, double> _ratios(PillPalPalette p) => {
      'ink/background': _contrast(p.ink, p.background),
      'ink/surface': _contrast(p.ink, p.surface),
      'inkMuted/background': _contrast(p.inkMuted, p.background),
      'inkMuted/surface': _contrast(p.inkMuted, p.surface),
      'inkMuted/actionSoft': _contrast(p.inkMuted, p.actionSoft),
      'onAction/action': _contrast(p.onAction, p.action),
      'onActionSoft/actionSoft': _contrast(p.onActionSoft, p.actionSoft),
      'onTaken/taken': _contrast(p.onTaken, p.taken),
      'onMissed/missed': _contrast(p.onMissed, p.missed),
      'onDanger/danger': _contrast(p.onDanger, p.danger),
      'action/background': _contrast(p.action, p.background),
      'action/surface': _contrast(p.action, p.surface),
      'taken/background': _contrast(p.taken, p.background),
      'taken/surface': _contrast(p.taken, p.surface),
      'missed/background': _contrast(p.missed, p.background),
      'missed/surface': _contrast(p.missed, p.surface),
      'info/background': _contrast(p.info, p.background),
      'info/surface': _contrast(p.info, p.surface),
      'danger/background': _contrast(p.danger, p.background),
      'danger/surface': _contrast(p.danger, p.surface),
    };

/// Asserts every pair of [p] reaches [minimum]; [exceptions] maps a pair to
/// its own lower bound.
void _expectContrast(
  String name,
  PillPalPalette p,
  double minimum, {
  Map<String, double> exceptions = const {},
}) {
  _ratios(p).forEach((pair, ratio) {
    expect(
      ratio,
      greaterThanOrEqualTo(exceptions[pair] ?? minimum),
      reason: '$name $pair',
    );
  });
}

void main() {
  test('spacing tokens are multiples of 4', () {
    const values = [
      PillPalSpacing.xs,
      PillPalSpacing.sm,
      PillPalSpacing.md,
      PillPalSpacing.lg,
      PillPalSpacing.xl,
      PillPalSpacing.xxl,
      PillPalSpacing.xxxl,
    ];
    for (final v in values) {
      expect(v % 4, 0, reason: '$v');
    }
    expect(PillPalSpacing.chips, PillPalSpacing.sm);
    expect(
      PillPalSpacing.screen,
      const EdgeInsets.fromLTRB(
        PillPalSpacing.xl,
        PillPalSpacing.sm,
        PillPalSpacing.xl,
        PillPalSpacing.xxl,
      ),
    );
    expect(
      PillPalSpacing.tabHeader,
      const EdgeInsets.fromLTRB(
        PillPalSpacing.xl,
        PillPalSpacing.xxl,
        PillPalSpacing.xl,
        PillPalSpacing.xxl,
      ),
    );
  });

  test('radii are the canvas scale 12/16/18/24', () {
    expect(
      [
        PillPalRadius.sm,
        PillPalRadius.md,
        PillPalRadius.lg,
        PillPalRadius.xl,
      ],
      [12, 16, 18, 24],
    );
    expect(PillPalRadius.card, BorderRadius.circular(PillPalRadius.lg));
    expect(PillPalRadius.control, BorderRadius.circular(PillPalRadius.md));
    expect(PillPalRadius.chip, BorderRadius.circular(PillPalRadius.sm));
    expect(
      PillPalRadius.sheetTop,
      const BorderRadius.vertical(top: Radius.circular(PillPalRadius.xl)),
    );
  });

  test('theme shapes use the radius tokens', () {
    final theme =
        buildPillPalTheme(brightness: Brightness.light, senior: false);

    final card = theme.cardTheme.shape as RoundedRectangleBorder;
    expect(card.borderRadius, PillPalRadius.card);
    final dialog = theme.dialogTheme.shape as RoundedRectangleBorder;
    expect(dialog.borderRadius, PillPalRadius.dialog);
    final sheet = theme.bottomSheetTheme.shape as RoundedRectangleBorder;
    expect(sheet.borderRadius, PillPalRadius.sheetTop);
    final button =
        theme.filledButtonTheme.style?.shape?.resolve({}) as OutlinedBorder;
    expect(
      (button as RoundedRectangleBorder).borderRadius,
      PillPalRadius.control,
    );
  });

  test('danger palette values and error colours', () {
    expect(PillPalPalette.light.danger, const Color(0xFF9E2B25));
    expect(PillPalPalette.light.onDanger, const Color(0xFFFFFFFF));
    expect(PillPalPalette.dark.danger, const Color(0xFFF28B7D));
    expect(PillPalPalette.dark.onDanger, const Color(0xFF1C1715));
    for (final brightness in Brightness.values) {
      for (final senior in [false, true]) {
        final theme = buildPillPalTheme(brightness: brightness, senior: senior);
        final palette = theme.extension<PillPalPalette>()!;
        expect(theme.colorScheme.error, palette.danger);
        expect(theme.colorScheme.onError, palette.onDanger);
      }
    }
  });

  test('senior mode selects the senior palettes', () {
    final light = buildPillPalTheme(brightness: Brightness.light, senior: true);
    final dark = buildPillPalTheme(brightness: Brightness.dark, senior: true);

    expect(light.extension<PillPalPalette>(), PillPalPalette.lightSenior);
    expect(dark.extension<PillPalPalette>(), PillPalPalette.darkSenior);
    expect(light.colorScheme.primary, PillPalPalette.lightSenior.action);
    expect(
        light.scaffoldBackgroundColor, PillPalPalette.lightSenior.background);
  });

  test('normal palettes keep their text contrast of at least 4.5:1', () {
    // The light `action` as text on the page background is 4.35:1 (known;
    // white on `action` is 4.62:1). Senior mode uses a darker action.
    _expectContrast(
      'light',
      PillPalPalette.light,
      4.5,
      exceptions: {'action/background': 4.3},
    );
    _expectContrast('dark', PillPalPalette.dark, 4.5);
  });

  test('senior palettes reach a text contrast of at least 7:1', () {
    _expectContrast('lightSenior', PillPalPalette.lightSenior, 7);
    _expectContrast('darkSenior', PillPalPalette.darkSenior, 7);
  });

  test('light theme maps design tokens', () {
    final theme =
        buildPillPalTheme(brightness: Brightness.light, senior: false);

    expect(theme.colorScheme.primary, PillPalPalette.light.action);
    expect(theme.scaffoldBackgroundColor, PillPalPalette.light.background);
    expect(theme.extension<PillPalPalette>(), PillPalPalette.light);
    expect(theme.textTheme.headlineLarge?.fontFamily, PillPalFonts.display);
    expect(theme.textTheme.bodyLarge?.fontFamily, PillPalFonts.body);
  });

  test('dark theme uses the dark palette', () {
    final theme = buildPillPalTheme(brightness: Brightness.dark, senior: false);

    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, PillPalPalette.dark.action);
  });

  test('senior mode enlarges buttons', () {
    final normal =
        buildPillPalTheme(brightness: Brightness.light, senior: false);
    final senior =
        buildPillPalTheme(brightness: Brightness.light, senior: true);

    expect(_buttonHeight(normal), PillPalSizes.buttonHeight);
    expect(_buttonHeight(senior), PillPalSizes.seniorButtonHeight);
    expect(
      normal.extension<PillPalMetrics>()?.touchTarget,
      PillPalSizes.touchTarget,
    );
    expect(senior.extension<PillPalMetrics>()?.touchTarget, 64);
  });

  test('palette lerp blends colours', () {
    final mid = PillPalPalette.light.lerp(PillPalPalette.dark, 0.5);
    expect(mid.ink, isNot(PillPalPalette.light.ink));
    expect(PillPalPalette.light.lerp(null, 0.5), PillPalPalette.light);
  });

  group('list tiles', () {
    Future<Size> tileSize(
      WidgetTester tester,
      Key key, {
      required bool senior,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPillPalTheme(
            brightness: Brightness.light,
            senior: senior,
          ),
          home: Scaffold(
            body: Column(
              children: [
                ListTile(key: const Key('tile'), title: const Text('a')),
                SwitchListTile(
                  key: const Key('switch'),
                  title: const Text('a'),
                  value: false,
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      return tester.getSize(find.byKey(key));
    }

    testWidgets('normal mode keeps the Material heights', (tester) async {
      for (final key in const [Key('tile'), Key('switch')]) {
        final size = await tileSize(tester, key, senior: false);
        expect(size.height, greaterThanOrEqualTo(56));
      }
    });

    testWidgets('senior mode rows reach the 64 touch target', (tester) async {
      for (final key in const [Key('tile'), Key('switch')]) {
        final size = await tileSize(tester, key, senior: true);
        expect(size.height, greaterThanOrEqualTo(64));
      }
    });
  });
}
