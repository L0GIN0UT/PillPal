import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/theme/app_theme.dart';

/// [home] in a themed app; [reduced] turns on `disableAnimations` for the
/// subtree only, which is what the widgets' own reduced-motion branch reads.
Widget motionApp(Widget home, {bool reduced = false}) {
  return MaterialApp(
    theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
    // Only set when asked: the system flag of a test must reach the app.
    builder: (context, child) => reduced
        ? MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          )
        : child!,
    home: Scaffold(body: home),
  );
}

/// Turns on the system "remove animations" flag, as on a device: it also
/// makes Flutter shorten every route and controller (`PillPalMotion.reduced`).
void useSystemReducedMotion(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}
