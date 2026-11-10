import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/app.dart';
import 'package:pillpal/src/theme/app_theme.dart';

/// Text scales of the matrix: the default and the largest system scale.
const List<double> uiMatrixScales = [1.0, 2.0];

/// Logical screens of the matrix: a common phone and a small one.
const List<Size> uiMatrixSizes = [Size(360, 800), Size(320, 568)];

/// The one text scale at which `expectContrast` renders the screen: the
/// guideline reads pixels, which is slow, and a larger scale does not change
/// the colours.
const double uiContrastScale = 1.0;

/// The one screen size of `expectContrast`.
const Size uiContrastSize = Size(360, 800);

/// Lowest contrast of text in senior cells (docs/design.md: 7:1); normal
/// cells use the framework's `textContrastGuideline` (4.5:1, 3:1 for large
/// text).
const double uiSeniorContrastRatio = 7;

/// One cell of the UI matrix.
class UiMatrixCase {
  /// Creates a cell.
  const UiMatrixCase({
    required this.brightness,
    required this.senior,
    required this.locale,
    required this.scale,
    required this.size,
  });

  /// Light or dark theme.
  final Brightness brightness;

  /// Senior mode (larger targets, text x1.3, senior palette).
  final bool senior;

  /// `ru` or `en`.
  final Locale locale;

  /// System text scale before the senior multiplier.
  final double scale;

  /// Logical screen size.
  final Size size;

  /// Minimum touch target of the mode.
  double get touchTarget =>
      senior ? PillPalSizes.seniorButtonHeight : PillPalSizes.touchTarget;

  /// Human-readable name, used in failure messages and keys.
  String get label => '${brightness.name} ${senior ? 'senior' : 'normal'} '
      '${locale.languageCode} x$scale ${size.width.toInt()}x'
      '${size.height.toInt()}';

  @override
  String toString() => label;
}

/// Called after a cell is pumped, to open sheets or assert on the result.
typedef UiMatrixCheck = Future<void> Function(
  WidgetTester tester,
  UiMatrixCase cell,
);

/// Pumps the widget made by [builder] in every cell of
/// {light, dark} x {normal, senior} x {ru, en} x [scales] x [sizes], with the
/// app's own theme builder, localizations and senior text scale. Fails,
/// naming the cell, on any exception (a layout overflow included). [check]
/// runs in each cell after the first frame.
///
/// With [expectTouchTargets] every tappable in the cell must be at least as
/// large as the touch target of the mode (see [expectTouchTargetsOf]).
///
/// With [expectContrast] the text on screen must meet the contrast of the
/// mode: `textContrastGuideline` in normal cells and 7:1 in senior cells. It
/// is checked only where the scale is [uiContrastScale] and the screen is
/// [uiContrastSize], so 8 cells of the full matrix (light and dark, normal
/// and senior, RU and EN) pay for the pixel comparison.
///
/// [wrap] puts the whole app inside something, such as a `ProviderScope`:
/// routes (sheets, dialogs) are built under the app's navigator, so a scope
/// that [builder] adds would not reach them.
///
/// [builder] runs inside the app, so it may read `Theme`, the palette and
/// `AppLocalizations`. The widget is placed at the top start of the screen
/// with loose constraints, so it is not stretched or scrolled for free.
///
/// Limit: vertical overflow inside a scrollable (a list, a sheet that
/// scrolls) is not an error and is not detected; only overflow of a box with
/// bounded size is, which is what a wrapped Row, a fixed-width label or a
/// clipped button produces.
Future<void> pumpUiMatrix(
  WidgetTester tester,
  Widget Function(BuildContext context) builder, {
  UiMatrixCheck? check,
  List<double> scales = uiMatrixScales,
  List<Size> sizes = uiMatrixSizes,
  bool expectTouchTargets = false,
  bool expectContrast = false,
  Finder? heightOnlyWithin,
  Widget Function(Widget app)? wrap,
}) async {
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final senior in [false, true]) {
      for (final locale in AppLocalizations.supportedLocales) {
        for (final scale in scales) {
          for (final size in sizes) {
            final cell = UiMatrixCase(
              brightness: brightness,
              senior: senior,
              locale: locale,
              scale: scale,
              size: size,
            );
            tester.view.physicalSize = size;
            final app = _app(cell, builder);
            await tester.pumpWidget(wrap == null ? app : wrap(app));
            await tester.pump();
            _failOnException(tester, cell, 'pump');
            if (expectTouchTargets) {
              expectTouchTargetsOf(
                tester,
                cell,
                heightOnlyWithin: heightOnlyWithin,
              );
            }
            if (expectContrast &&
                cell.scale == uiContrastScale &&
                cell.size == uiContrastSize) {
              await expectContrastOf(tester, cell);
            }
            if (check != null) {
              await check(tester, cell);
              _failOnException(tester, cell, 'check');
            }
          }
        }
      }
    }
  }
}

/// Expects every tappable (an [InkWell] with `onTap`, an enabled button, an
/// [IconButton] or a [ListTile] with `onTap`) on screen to be at least
/// `cell.touchTarget` high and wide.
///
/// Tappables inside [heightOnlyWithin] are checked for height only: the
/// cells of a seven-column grid (the History calendar) share the screen width
/// and cannot be a target wide on a phone.
void expectTouchTargetsOf(
  WidgetTester tester,
  UiMatrixCase cell, {
  Finder? heightOnlyWithin,
}) {
  final tappables = find.byWidgetPredicate(
    (widget) =>
        (widget is InkWell && widget.onTap != null) ||
        (widget is ButtonStyleButton && widget.onPressed != null) ||
        (widget is IconButton && widget.onPressed != null) ||
        (widget is ListTile && widget.onTap != null),
  );
  final heightOnly = heightOnlyWithin == null
      ? const <Element>{}
      : find
          .descendant(of: heightOnlyWithin, matching: tappables)
          .evaluate()
          .toSet();
  final elements = tappables.evaluate().toList();
  for (var i = 0; i < elements.length; i++) {
    final size = tester.getSize(tappables.at(i));
    expect(
      size.height,
      greaterThanOrEqualTo(cell.touchTarget),
      reason:
          'tappable #$i (${elements[i].widget.runtimeType}) is too low in "${cell.label}"',
    );
    if (heightOnly.contains(elements[i])) {
      continue;
    }
    expect(
      size.width,
      greaterThanOrEqualTo(cell.touchTarget),
      reason:
          'tappable #$i (${elements[i].widget.runtimeType}) is too narrow in "${cell.label}"',
    );
  }
}

/// Expects the text on screen to be readable in the mode of [cell]: the
/// framework's contrast guideline (4.5:1, large text 3:1) in normal mode,
/// 7:1 for every [Text] in senior mode. Reads the rendered pixels, so a text
/// over a gradient or an image is measured as drawn.
Future<void> expectContrastOf(WidgetTester tester, UiMatrixCase cell) async {
  final semantics = tester.ensureSemantics();
  try {
    final guideline = cell.senior
        ? CustomMinimumContrastGuideline(
            finder: find.byType(Text),
            minimumRatio: uiSeniorContrastRatio,
          )
        : textContrastGuideline;
    await expectLater(
      tester,
      meetsGuideline(guideline),
      reason: 'contrast in "${cell.label}"',
    );
  } finally {
    semantics.dispose();
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
