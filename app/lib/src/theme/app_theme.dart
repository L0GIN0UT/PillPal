import 'package:flutter/material.dart';

import 'component_themes.dart';
import 'palette.dart';
import 'sizes.dart';
import 'text_theme.dart';

// Existing imports of this file keep working after the split of R1.
export 'sizes.dart';
export 'text_theme.dart';

/// Builds the app theme for [brightness]; [senior] enlarges controls.
ThemeData buildPillPalTheme({
  required Brightness brightness,
  required bool senior,
}) {
  final palette = brightness == Brightness.light
      ? (senior ? PillPalPalette.lightSenior : PillPalPalette.light)
      : (senior ? PillPalPalette.darkSenior : PillPalPalette.dark);
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: _colorScheme(brightness, palette),
    scaffoldBackgroundColor: palette.background,
    fontFamily: PillPalFonts.body,
    textTheme: buildPillPalTextTheme(palette),
    extensions: <ThemeExtension<dynamic>>[
      palette,
      senior ? PillPalMetrics.senior : PillPalMetrics.normal,
    ],
  );
  return applyComponentThemes(base, palette, senior: senior);
}

/// docs/design.md "Mapping to the colour scheme": Material widgets that read
/// the scheme get the design tokens.
ColorScheme _colorScheme(Brightness brightness, PillPalPalette palette) {
  return ColorScheme(
    brightness: brightness,
    primary: palette.action,
    onPrimary: palette.onAction,
    secondary: palette.taken,
    onSecondary: palette.onTaken,
    secondaryContainer: palette.selected,
    onSecondaryContainer: palette.onSelected,
    tertiary: palette.missed,
    onTertiary: palette.onMissed,
    tertiaryContainer: palette.missedSoft,
    onTertiaryContainer: palette.onMissedSoft,
    error: palette.danger,
    onError: palette.onDanger,
    errorContainer: palette.dangerSoft,
    onErrorContainer: palette.onDangerSoft,
    surface: palette.surface,
    onSurface: palette.ink,
    surfaceContainerHighest: palette.raised,
    onSurfaceVariant: palette.inkMuted,
    outline: palette.outline,
    outlineVariant: palette.border,
    scrim: palette.scrim,
    surfaceTint: Colors.transparent,
  );
}
