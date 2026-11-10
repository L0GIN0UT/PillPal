import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/app.dart';
import 'package:pillpal/src/theme/app_theme.dart';

/// Text scales of the matrix: the default and the largest system scale.
const List<double> uiMatrixScales = [1.0, 2.0];

/// Phone-sized logical screen (width x height) of the matrix.
const Size uiMatrixScreen = Size(360, 800);

/// One cell of the UI matrix.
class UiMatrixCase {
  /// Creates a cell.
  const UiMatrixCase({
    required this.brightness,
    required this.senior,
    required this.locale,
    required this.scale,
  });

  /// Light or dark theme.
  final Brightness brightness;

  /// Senior mode (larger targets, text x1.3, senior palette).
  final bool senior;

  /// `ru` or `en`.
  final Locale locale;

  /// System text scale before the senior multiplier.
  final double scale;

  /// Human-readable name, used in failure messages and keys.
  String get label => '${brightness.name} ${senior ? 'senior' : 'normal'} '
      '${locale.languageCode} x$scale';

  @override
  String toString() => label;
}

/// Called after a cell is pumped, to open sheets or assert on the result.
typedef UiMatrixCheck = Future<void> Function(
  WidgetTester tester,
  UiMatrixCase cell,
);

/// Pumps the widget made by [builder] in every cell of
/// {light, dark} x {normal, senior} x {ru, en} x [scales], with the app's own
/// theme builder, localizations and senior text scale, on a phone-sized
/// screen. Fails, naming the cell, on any exception (a layout overflow
/// included). [check] runs in each cell after the first frame.
///
/// [builder] runs inside the app, so it may read `Theme`, the palette and
/// `AppLocalizations`. The widget is placed at the top start of the screen
/// with loose constraints, so it is not stretched or scrolled for free.
Future<void> pumpUiMatrix(
  WidgetTester tester,
  Widget Function(BuildContext context) builder, {
  UiMatrixCheck? check,
  List<double> scales = uiMatrixScales,
}) async {
  tester.view
    ..physicalSize = uiMatrixScreen
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final senior in [false, true]) {
      for (final locale in AppLocalizations.supportedLocales) {
        for (final scale in scales) {
          final cell = UiMatrixCase(
            brightness: brightness,
            senior: senior,
            locale: locale,
            scale: scale,
          );
          await tester.pumpWidget(_app(cell, builder));
          await tester.pump();
          _failOnException(tester, cell, 'pump');
          if (check != null) {
            await check(tester, cell);
            _failOnException(tester, cell, 'check');
          }
        }
      }
    }
  }
}

void _failOnException(WidgetTester tester, UiMatrixCase cell, String step) {
  final error = tester.takeException();
  if (error != null) {
    fail('UI matrix cell "${cell.label}" ($step): $error');
  }
}

Widget _app(UiMatrixCase cell, Widget Function(BuildContext) builder) {
  final brightness = cell.brightness;
  return MaterialApp(
    // A new key per cell: no state leaks from the previous one.
    key: ValueKey(cell.label),
    locale: cell.locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    theme: buildPillPalTheme(
      brightness: Brightness.light,
      senior: cell.senior,
    ),
    darkTheme: buildPillPalTheme(
      brightness: Brightness.dark,
      senior: cell.senior,
    ),
    builder: (context, app) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(cell.scale),
      ),
      child: SeniorTextScale(enabled: cell.senior, child: app!),
    ),
    home: Scaffold(
      body: Align(
        alignment: AlignmentDirectional.topStart,
        child: Builder(builder: builder),
      ),
    ),
  );
}
