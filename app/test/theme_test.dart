import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';

double _buttonHeight(ThemeData theme) {
  final size = theme.filledButtonTheme.style?.minimumSize?.resolve({});
  return size?.height ?? 0;
}

void main() {
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
  });

  test('palette lerp blends colours', () {
    final mid = PillPalPalette.light.lerp(PillPalPalette.dark, 0.5);
    expect(mid.ink, isNot(PillPalPalette.light.ink));
    expect(PillPalPalette.light.lerp(null, 0.5), PillPalPalette.light);
  });
}
