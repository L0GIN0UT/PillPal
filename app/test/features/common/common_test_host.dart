import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/localization_delegates.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';

/// The palette of a theme, for expectations.
PillPalPalette paletteOf({
  Brightness brightness = Brightness.light,
  bool senior = false,
}) =>
    buildPillPalTheme(brightness: brightness, senior: senior)
        .extension<PillPalPalette>()!;

/// Pumps [child] at the top start of a themed app with the app's
/// localizations; [scale] is the system text scale and [size] the screen.
Future<void> pumpThemed(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  bool senior = false,
  Locale locale = const Locale('en'),
  double scale = 1,
  Size size = const Size(360, 800),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: pillPalLocalizationsDelegates,
      theme: buildPillPalTheme(brightness: brightness, senior: senior),
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: app!,
      ),
      // A scroll view, like every screen: a tall widget is not an overflow.
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: AlignmentDirectional.topStart,
            child: child,
          ),
        ),
      ),
    ),
  );
  // The theme animates when a test pumps another one (senior mode).
  await tester.pumpAndSettle();
}
