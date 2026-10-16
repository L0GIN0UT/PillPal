import 'package:flutter/material.dart';

import 'palette.dart';

/// Font families bundled in `assets/fonts` (docs/design.md).
abstract final class PillPalFonts {
  /// Headings.
  static const String display = 'Rubik';

  /// Body text and controls.
  static const String body = 'Nunito';
}

/// Size tokens; senior mode scales touch targets (docs/design.md).
abstract final class PillPalSizes {
  /// Minimum button height in normal mode.
  static const double buttonHeight = 52;

  /// Minimum button height in senior mode.
  static const double seniorButtonHeight = 64;

  /// Minimum touch target in normal mode (docs/design.md: >= 44).
  static const double touchTarget = 44;

  /// Text scale multiplier applied on top of the system scale in senior mode.
  static const double seniorTextScale = 1.3;

  /// Default corner radius of cards.
  static const double cardRadius = 20;

  /// Default corner radius of buttons and inputs.
  static const double controlRadius = 16;
}

/// Size metrics of the current mode, for widgets that size touch targets
/// themselves (chips, calendar cells, inline buttons).
@immutable
class PillPalMetrics extends ThemeExtension<PillPalMetrics> {
  /// Creates metrics.
  const PillPalMetrics({required this.touchTarget});

  /// Normal mode.
  static const PillPalMetrics normal =
      PillPalMetrics(touchTarget: PillPalSizes.touchTarget);

  /// Senior mode: touch targets of at least 64 (docs/design.md).
  static const PillPalMetrics senior =
      PillPalMetrics(touchTarget: PillPalSizes.seniorButtonHeight);

  /// Minimum width and height of a touch target.
  final double touchTarget;

  @override
  PillPalMetrics copyWith({double? touchTarget}) =>
      PillPalMetrics(touchTarget: touchTarget ?? this.touchTarget);

  @override
  PillPalMetrics lerp(ThemeExtension<PillPalMetrics>? other, double t) =>
      other is PillPalMetrics && t >= 0.5 ? other : this;
}

/// Access to [PillPalMetrics] of the current theme.
extension PillPalMetricsOf on BuildContext {
  /// The current metrics (normal when the theme has none).
  PillPalMetrics get metrics =>
      Theme.of(this).extension<PillPalMetrics>() ?? PillPalMetrics.normal;
}

/// Builds the app theme for [brightness]; [senior] enlarges controls.
ThemeData buildPillPalTheme({
  required Brightness brightness,
  required bool senior,
}) {
  final palette = brightness == Brightness.light
      ? PillPalPalette.light
      : PillPalPalette.dark;
  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: palette.action,
    onPrimary: palette.onAction,
    secondary: palette.taken,
    onSecondary: palette.onTaken,
    tertiary: palette.missed,
    onTertiary: palette.onMissed,
    error: const Color(0xFFB3261E),
    onError: const Color(0xFFFFFFFF),
    surface: palette.surface,
    onSurface: palette.ink,
    onSurfaceVariant: palette.inkMuted,
    outline: palette.border,
  );
  final buttonHeight =
      senior ? PillPalSizes.seniorButtonHeight : PillPalSizes.buttonHeight;
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(PillPalSizes.controlRadius),
  );
  const buttonText = TextStyle(
    fontFamily: PillPalFonts.body,
    fontWeight: FontWeight.w800,
    fontSize: 17,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: palette.background,
    fontFamily: PillPalFonts.body,
    textTheme: _textTheme(palette),
    extensions: <ThemeExtension<dynamic>>[
      palette,
      senior ? PillPalMetrics.senior : PillPalMetrics.normal,
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: palette.background,
      foregroundColor: palette.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: PillPalFonts.display,
        fontWeight: FontWeight.w700,
        fontSize: 24,
        color: palette.ink,
      ),
    ),
    cardTheme: CardThemeData(
      color: palette.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PillPalSizes.cardRadius),
        side: BorderSide(color: palette.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: Size(64, buttonHeight),
        shape: buttonShape,
        textStyle: buttonText,
        backgroundColor: palette.action,
        foregroundColor: palette.onAction,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: Size(64, buttonHeight),
        shape: buttonShape,
        textStyle: buttonText,
        foregroundColor: palette.ink,
        side: BorderSide(color: palette.action, width: 2),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: Size(48, buttonHeight),
        textStyle: buttonText,
        foregroundColor: palette.inkMuted,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PillPalSizes.controlRadius),
        borderSide: BorderSide(color: palette.border, width: 2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PillPalSizes.controlRadius),
        borderSide: BorderSide(color: palette.border, width: 2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PillPalSizes.controlRadius),
        borderSide: BorderSide(color: palette.action, width: 2),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: palette.surface,
      indicatorColor: palette.actionSoft,
      height: senior ? 88 : 76,
    ),
    dividerTheme: DividerThemeData(color: palette.border, thickness: 1),
  );
}

TextTheme _textTheme(PillPalPalette palette) {
  TextStyle display(double size, FontWeight weight) => TextStyle(
        fontFamily: PillPalFonts.display,
        fontSize: size,
        fontWeight: weight,
        color: palette.ink,
      );
  TextStyle body(double size, FontWeight weight, Color color) => TextStyle(
        fontFamily: PillPalFonts.body,
        fontSize: size,
        fontWeight: weight,
        color: color,
      );
  return TextTheme(
    displaySmall: display(36, FontWeight.w700),
    headlineLarge: display(32, FontWeight.w700),
    headlineMedium: display(26, FontWeight.w700),
    headlineSmall: display(22, FontWeight.w600),
    titleLarge: display(20, FontWeight.w600),
    titleMedium: body(17, FontWeight.w800, palette.ink),
    titleSmall: body(15, FontWeight.w800, palette.ink),
    bodyLarge: body(17, FontWeight.w400, palette.ink),
    bodyMedium: body(16, FontWeight.w400, palette.ink),
    bodySmall: body(14, FontWeight.w600, palette.inkMuted),
    labelLarge: body(16, FontWeight.w800, palette.ink),
    labelMedium: body(14, FontWeight.w700, palette.ink),
    labelSmall: body(12, FontWeight.w700, palette.inkMuted),
  );
}
