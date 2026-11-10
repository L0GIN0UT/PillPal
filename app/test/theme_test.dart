import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal/src/theme/radius.dart';
import 'package:pillpal/src/theme/shadows.dart';
import 'package:pillpal/src/theme/spacing.dart';

ThemeData _theme(Brightness brightness, {bool senior = false}) =>
    buildPillPalTheme(brightness: brightness, senior: senior);

/// Asserts family, size, weight and line height (px) of a text style.
void _expectStyle(
  TextStyle? style, {
  required String family,
  required double size,
  required double line,
  required FontWeight weight,
}) {
  expect(style, isNotNull);
  expect(style!.fontFamily, family);
  expect(style.fontSize, size);
  expect(style.fontWeight, weight);
  expect((style.height ?? 0) * size, closeTo(line, 0.01));
}

void main() {
  test('spacing tokens are multiples of 4 plus huge', () {
    const values = [
      PillPalSpacing.xs,
      PillPalSpacing.sm,
      PillPalSpacing.md,
      PillPalSpacing.lg,
      PillPalSpacing.xl,
      PillPalSpacing.xxl,
      PillPalSpacing.xxxl,
      PillPalSpacing.huge,
    ];
    for (final v in values) {
      expect(v % 4, 0, reason: '$v');
    }
    expect(PillPalSpacing.huge, 40);
    expect(PillPalSpacing.chips, PillPalSpacing.sm);
    expect(PillPalSpacing.sectionTop, PillPalSpacing.xxl);
    expect(PillPalSpacing.sectionBottom, PillPalSpacing.md);
  });

  test('tab screens use side padding 16, forms and sheets 20', () {
    expect(
      PillPalSpacing.screen,
      const EdgeInsets.fromLTRB(
        PillPalSpacing.lg,
        PillPalSpacing.sm,
        PillPalSpacing.lg,
        PillPalSpacing.xxl,
      ),
    );
    expect(
      PillPalSpacing.tabHeader,
      const EdgeInsets.fromLTRB(
        PillPalSpacing.lg,
        PillPalSpacing.xxl,
        PillPalSpacing.lg,
        PillPalSpacing.xxl,
      ),
    );
    expect(
      PillPalSpacing.form,
      const EdgeInsets.fromLTRB(
        PillPalSpacing.xl,
        PillPalSpacing.sm,
        PillPalSpacing.xl,
        PillPalSpacing.xxxl,
      ),
    );
    expect(
      PillPalSpacing.sheet,
      const EdgeInsets.fromLTRB(
        PillPalSpacing.xl,
        PillPalSpacing.sm,
        PillPalSpacing.xl,
        PillPalSpacing.xxxl - 4,
      ),
    );
  });

  test('radii are the scale 12/16/20/28 plus the pill', () {
    expect(
      [
        PillPalRadius.sm,
        PillPalRadius.md,
        PillPalRadius.lg,
        PillPalRadius.xl,
      ],
      [12, 16, 20, 28],
    );
    expect(PillPalRadius.card, BorderRadius.circular(PillPalRadius.lg));
    expect(PillPalRadius.control, BorderRadius.circular(PillPalRadius.md));
    expect(PillPalRadius.chip, BorderRadius.circular(PillPalRadius.sm));
    expect(PillPalRadius.hero, BorderRadius.circular(PillPalRadius.xl));
    expect(PillPalRadius.dialog, BorderRadius.circular(PillPalRadius.xl));
    expect(
      PillPalRadius.sheetTop,
      const BorderRadius.vertical(top: Radius.circular(PillPalRadius.xl)),
    );
    expect(PillPalRadius.pill, const StadiumBorder());
    expect(PillPalRadius.navIndicator, 16);
    expect(PillPalRadius.checkbox, 7);
  });

  test('size tokens follow the spec', () {
    expect(PillPalSizes.statusDisc, 40);
    expect(PillPalSizes.statusDiscSenior, 52);
    expect(PillPalSizes.roundCheck, 48);
    expect(PillPalSizes.profileChip, 44);
    expect(PillPalSizes.navHeight, 88);
    expect(PillPalSizes.navHeightSenior, 104);
    expect(PillPalSizes.heroPadding, 20);
    expect(PillPalSizes.emptyDisc, 96);
    expect(PillPalSizes.iconEmpty, 44);
    expect(PillPalSizes.fab, 56);
    expect(PillPalSizes.progressRing, 56);
    expect(PillPalSizes.qrCode, 220);
    expect(PillPalSizes.buttonHeight, 52);
    expect(PillPalSizes.seniorButtonHeight, 64);
    expect(PillPalSizes.seniorTakeHeight, 76);
    expect(PillPalSizes.touchTarget, 44);
    expect(PillPalSizes.seniorTextScale, 1.3);
    expect(PillPalSizes.titleMaxScale, 1.5);
    expect(PillPalSizes.heroNameMaxScale, 1.6);
    expect(PillPalSizes.navLabelMaxScale, 1.15);
    expect(PillPalSizes.fabLabelMaxScale, 1.3);
    expect(PillPalSizes.compactRowScale, 1.6);
    expect(PillPalSizes.fabSenior, 64);
    expect(
      [
        PillPalSizes.avatarSm,
        PillPalSizes.avatarMd,
        PillPalSizes.avatarLg,
      ],
      [40, 48, 64],
    );
    expect(PillPalSizes.statusPill, 28);
    expect(PillPalSizes.chipHeight, 36);
    expect(PillPalSizes.listRowMin, 60);
    expect(PillPalSizes.listRowMinSenior, 76);
    expect(PillPalSizes.bannerPaddingVertical, 14);
    expect(PillPalSizes.bannerPaddingHorizontal, 16);
    expect(PillPalSizes.buttonMinWidth, 64);
    expect(PillPalSizes.elevationLevel2, 2);
    expect(PillPalSizes.elevationLevel1, 1);
    expect(PillPalRadius.navTop, 24);
  });

  test('shadows are two layers per level, light only', () {
    expect(PillPalShadows.level1, hasLength(2));
    expect(PillPalShadows.level2, hasLength(2));
    expect(PillPalShadows.nav, isNotEmpty);
    expect(PillPalShadows.nav.first.offset, const Offset(0, -6));
    expect(
      PillPalShadows.forBrightness(Brightness.light, PillPalShadows.level1),
      PillPalShadows.level1,
    );
    expect(
      PillPalShadows.forBrightness(Brightness.dark, PillPalShadows.level2),
      isEmpty,
    );
  });

  test('senior mode selects the senior palettes', () {
    final light = _theme(Brightness.light, senior: true);
    final dark = _theme(Brightness.dark, senior: true);

    expect(light.extension<PillPalPalette>(), PillPalPalette.lightSenior);
    expect(dark.extension<PillPalPalette>(), PillPalPalette.darkSenior);
    expect(light.colorScheme.primary, PillPalPalette.lightSenior.action);
  });

  test('palettes are distinct per theme and expose the added tokens', () {
    final palettes = [
      PillPalPalette.light,
      PillPalPalette.lightSenior,
      PillPalPalette.dark,
      PillPalPalette.darkSenior,
    ];
    expect(palettes.toSet(), hasLength(4));
    for (final p in palettes) {
      expect(p.takenSoft, isNot(p.taken));
      expect(p.copyWith(hero: p.ink).hero, p.ink);
      expect(p.copyWith(scrim: p.ink).scrim, p.ink);
      expect(p.copyWith(onHeroAction: p.ink).onHeroAction, p.ink);
    }
    expect(PillPalPalette.light.danger, const Color(0xFFBD2A2A));
    expect(PillPalPalette.dark.danger, const Color(0xFFFF8F86));
    expect(PillPalPalette.dark.onDanger, const Color(0xFF3A0A0A));
    expect(PillPalPalette.dark.background, const Color(0xFF202A28));
  });

  test('palette lerp blends every colour and ignores foreign extensions', () {
    final mid = PillPalPalette.light.lerp(PillPalPalette.dark, 0.5);
    expect(mid.ink, isNot(PillPalPalette.light.ink));
    expect(mid.hero, isNot(PillPalPalette.light.hero));
    expect(mid.scrim, isNot(PillPalPalette.light.scrim));
    expect(PillPalPalette.light.lerp(null, 0.5), PillPalPalette.light);
    expect(
      PillPalPalette.light.lerp(PillPalPalette.dark, 1).missedSoft,
      PillPalPalette.dark.missedSoft,
    );
  });

  test('the text theme follows the type table', () {
    final text = _theme(Brightness.light).textTheme;
    const display = PillPalFonts.display;
    const body = PillPalFonts.body;
    expect(display, 'Manrope');
    expect(body, 'GolosText');
    _expectStyle(text.displaySmall,
        family: display, size: 32, line: 38, weight: FontWeight.w800);
    expect(text.displaySmall?.letterSpacing, -0.6);
    // Current screens still use headlineLarge as their title.
    _expectStyle(text.headlineLarge,
        family: display, size: 32, line: 38, weight: FontWeight.w800);
    _expectStyle(text.headlineMedium,
        family: display, size: 26, line: 30, weight: FontWeight.w800);
    _expectStyle(text.headlineSmall,
        family: display, size: 24, line: 30, weight: FontWeight.w800);
    _expectStyle(text.titleLarge,
        family: display, size: 20, line: 24, weight: FontWeight.w700);
    _expectStyle(text.titleMedium,
        family: display, size: 18, line: 22, weight: FontWeight.w700);
    _expectStyle(text.titleSmall,
        family: body, size: 15, line: 20, weight: FontWeight.w600);
    _expectStyle(text.bodyLarge,
        family: body, size: 17, line: 22, weight: FontWeight.w400);
    _expectStyle(text.bodyMedium,
        family: body, size: 15, line: 20, weight: FontWeight.w400);
    _expectStyle(text.bodySmall,
        family: body, size: 14, line: 19, weight: FontWeight.w400);
    _expectStyle(text.labelLarge,
        family: body, size: 17, line: 20, weight: FontWeight.w700);
    _expectStyle(text.labelMedium,
        family: body, size: 14, line: 17, weight: FontWeight.w600);
    _expectStyle(text.labelSmall,
        family: body, size: 13, line: 16, weight: FontWeight.w500);
    // Letter-spacing 0 everywhere except screen titles.
    for (final style in [text.titleLarge, text.titleMedium, text.bodyLarge]) {
      expect(style?.letterSpacing ?? 0, 0);
    }
  });

  test('display slots are tabular Manrope 800 for times', () {
    final text = _theme(Brightness.light).textTheme;
    for (final style in [text.displayLarge, text.displayMedium]) {
      expect(style?.fontFamily, PillPalFonts.display);
      expect(style?.fontWeight, FontWeight.w800);
      expect(style?.fontFeatures, contains(const FontFeature.tabularFigures()));
    }
    expect(text.displayLarge?.fontSize, 80);
    expect(text.displayMedium?.fontSize, 22);
  });

  test('numerals are Manrope 800 with tabular figures', () {
    final numeral = _theme(Brightness.light).textTheme.numeral;
    _expectStyle(numeral,
        family: PillPalFonts.display,
        size: 22,
        line: 26,
        weight: FontWeight.w800);
    expect(numeral.fontFeatures, contains(const FontFeature.tabularFigures()));
  });

  test('theme text colours come from the palette', () {
    for (final brightness in Brightness.values) {
      final theme = _theme(brightness);
      final p = theme.extension<PillPalPalette>()!;
      expect(theme.textTheme.titleLarge?.color, p.ink);
      expect(theme.textTheme.bodyLarge?.color, p.ink);
      expect(theme.textTheme.bodySmall?.color, p.inkMuted);
      expect(theme.textTheme.labelSmall?.color, p.inkMuted);
      expect(theme.appBarTheme.titleTextStyle?.color, p.ink);
    }
  });

  test('senior mode enlarges the touch target and the app bar', () {
    final normal = _theme(Brightness.light);
    final senior = _theme(Brightness.light, senior: true);

    expect(
      normal.extension<PillPalMetrics>()?.touchTarget,
      PillPalSizes.touchTarget,
    );
    expect(senior.extension<PillPalMetrics>()?.touchTarget, 64);
    expect(normal.appBarTheme.toolbarHeight, isNull);
    expect(senior.appBarTheme.toolbarHeight, PillPalSizes.seniorButtonHeight);
  });

  group('list tiles', () {
    Future<Size> tileSize(
      WidgetTester tester,
      Key key, {
      required bool senior,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(Brightness.light, senior: senior),
          home: Scaffold(
            body: Column(
              children: [
                const ListTile(key: Key('tile'), title: Text('a')),
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
