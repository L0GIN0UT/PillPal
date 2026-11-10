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
    displayLarge: _numeral(palette.ink, size: alarmNumeralSize),
    displayMedium: _numeral(palette.ink, size: numeralSize),
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

/// Size of times and counters (the numeral style).
const double numeralSize = 22;

/// Size of the «Принял» label of the «Сейчас» card (B2-README section 5).
const double heroTakeSize = 18;

/// Size of the time on the full-screen alarm (B2-README section 5).
const double alarmNumeralSize = 80;

TextStyle _numeral(Color? color, {required double size}) => TextStyle(
      fontFamily: PillPalFonts.display,
      fontSize: size,
      height: size == numeralSize ? 26 / numeralSize : 1,
      fontWeight: FontWeight.w800,
      letterSpacing: 0,
      color: color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

/// Styles that are not a Material text slot.
extension PillPalText on TextTheme {
  /// Times and counters: Manrope 800 at 22 / 26 with tabular figures, so
  /// digits do not jump. The colour is the one of the surrounding text.
  TextStyle get numeral => _numeral(null, size: numeralSize);

  /// «Принял» in the «Сейчас» card: the button label at 18.
  TextStyle get heroTake =>
      (labelLarge ?? const TextStyle()).copyWith(fontSize: heroTakeSize);

  /// Label of a segment of a segmented control: 700 when selected, else 500
  /// (B2-README section 3, `segmented`).
  TextStyle segmentLabel({required bool selected}) =>
      (bodyMedium ?? const TextStyle()).copyWith(
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      );

  /// Title of a list row: body text in 500 (section 5).
  TextStyle get rowTitle =>
      (bodyLarge ?? const TextStyle()).copyWith(fontWeight: FontWeight.w500);

  /// Label of a radio row: body text, 700 when selected.
  TextStyle radioLabel({required bool selected}) =>
      (bodyLarge ?? const TextStyle()).copyWith(
        fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
      );
}
