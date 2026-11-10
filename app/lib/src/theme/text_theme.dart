import 'package:flutter/material.dart';

import 'palette.dart';

/// Font families bundled in `assets/fonts` (docs/design.md section "Fonts").
abstract final class PillPalFonts {
  /// Titles and numbers (Manrope 700 and 800).
  static const String display = 'Manrope';

  /// Body text and controls (Golos Text 400, 500, 600 and 700).
  static const String body = 'GolosText';
}

/// The type table of docs/design.md (B2-README section 5). Sizes are at
/// system scale 1.0; senior mode multiplies them by
/// `PillPalSizes.seniorTextScale` through the text scaler.
TextTheme buildPillPalTextTheme(PillPalPalette palette) {
  TextStyle style(
    String family,
    double size,
    double line,
    FontWeight weight,
    Color color, {
    double letterSpacing = 0,
  }) =>
      TextStyle(
        fontFamily: family,
        fontSize: size,
        height: line / size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
      );
  TextStyle display(double size, double line, FontWeight weight,
          {double letterSpacing = 0}) =>
      style(PillPalFonts.display, size, line, weight, palette.ink,
          letterSpacing: letterSpacing);
  TextStyle body(double size, double line, FontWeight weight, Color color) =>
      style(PillPalFonts.body, size, line, weight, color);

  // The screen title. Today's screens still read it from `headlineLarge`,
  // so both slots carry it until every screen uses `displaySmall` (R3-R7).
  final title = display(32, 38, FontWeight.w800, letterSpacing: -0.6);
  return TextTheme(
    displaySmall: title,
    headlineLarge: title,
    headlineMedium: display(26, 30, FontWeight.w800),
    headlineSmall: display(24, 30, FontWeight.w800),
    titleLarge: display(20, 24, FontWeight.w700),
    titleMedium: display(18, 22, FontWeight.w700),
    titleSmall: body(15, 20, FontWeight.w600, palette.ink),
    bodyLarge: body(17, 22, FontWeight.w400, palette.ink),
    bodyMedium: body(15, 20, FontWeight.w400, palette.ink),
    bodySmall: body(14, 19, FontWeight.w400, palette.inkMuted),
    labelLarge: body(17, 20, FontWeight.w700, palette.ink),
    labelMedium: body(14, 17, FontWeight.w600, palette.ink),
    labelSmall: body(13, 16, FontWeight.w500, palette.inkMuted),
  );
}

/// Styles that are not a Material text slot.
extension PillPalText on TextTheme {
  /// Times and counters: Manrope 800 at 22 / 26 with tabular figures, so
  /// digits do not jump. The colour is the one of the surrounding text.
  TextStyle get numeral => const TextStyle(
        fontFamily: PillPalFonts.display,
        fontSize: 22,
        height: 26 / 22,
        fontWeight: FontWeight.w800,
        letterSpacing: 0,
        fontFeatures: [FontFeature.tabularFigures()],
      );
}
