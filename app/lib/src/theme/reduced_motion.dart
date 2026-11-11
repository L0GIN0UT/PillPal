import 'package:flutter/material.dart';

/// [base] with the colour changes of buttons made instant: Material fades a
/// button between its enabled and disabled colours in `animationDuration`,
/// and reduced motion wants state changes without a transition
/// (docs/design/b2/README.md, "Motion"). The app wraps its screens in this
/// theme while `MediaQuery.disableAnimations` is on.
ThemeData withInstantStateChanges(ThemeData base) {
  ButtonStyle? instant(ButtonStyle? style) =>
      (style ?? const ButtonStyle()).copyWith(
        animationDuration: Duration.zero,
      );
  return base.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: instant(base.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: instant(base.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: instant(base.textButtonTheme.style),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: instant(base.elevatedButtonTheme.style),
    ),
  );
}
