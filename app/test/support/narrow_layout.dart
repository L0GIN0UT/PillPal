import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/app.dart';
import 'package:pillpal/src/settings/app_settings.dart';
import 'package:pillpal/src/theme/spacing.dart';

// Narrow screens and large text on real devices (Galaxy Z Fold cover and
// inner screens): renders whole app screens in the app's real fonts and
// finds text that a sibling squeezes to a few letters per line, and layout
// overflow. `docs/design.md` "Narrow screens and large text".

/// Logical screens: Z Fold cover (older and current), Z Fold inner (older
/// and current).
const List<Size> narrowSizes = [
  Size(280, 653),
  Size(344, 882),
  Size(673, 841),
  Size(884, 1104),
];

/// Width of the current Z Fold cover screen.
const double narrowCoverWidth = 344;

/// Width from which a screen is an unfolded inner screen.
const double narrowInnerWidth = 600;

/// System text scales: default, a common enlarged one, the largest.
const List<double> narrowScales = [1.0, 1.3, 2.0];

/// Device pixel ratio of the screenshots (layout uses logical sizes).
const double _shotPixelRatio = 2;

/// At most this many viewport pages of one screen are checked.
const int _maxPages = 8;

/// A text shorter than this is never called squeezed (a time, a count).
const int _minSqueezeLength = 7;

/// Where screenshots go: unset means none are written.
String? get narrowShotsDir => Platform.environment['NARROW_SHOTS_DIR'];

/// One cell of the matrix.
class NarrowCell {
  /// Creates a cell.
  const NarrowCell(this.size, this.scale, this.locale, {required this.senior});

  /// Logical screen size.
  final Size size;

  /// System text scale (senior mode multiplies it by 1.3).
  final double scale;

  /// `ru` or `en`.
  final Locale locale;

  /// Senior mode.
  final bool senior;

  /// Name used in findings and file names.
  String get label => '${size.width.toInt()}x${size.height.toInt()}-'
      '${locale.languageCode}-${senior ? 'senior' : 'normal'}-x$scale';
}

/// Every cell: [narrowSizes] x [narrowScales] x {ru, en} x {normal, senior}.
List<NarrowCell> narrowCells({
  List<Size> sizes = narrowSizes,
  List<double> scales = narrowScales,
}) =>
    [
      for (final locale in const [Locale('ru'), Locale('en')])
        for (final senior in const [false, true])
          for (final size in sizes)
            for (final scale in scales)
              NarrowCell(size, scale, locale, senior: senior),
    ];

/// Key of the boundary the screenshots are taken from.
const Key narrowShotKey = Key('narrow-shot');

/// Wraps the app for [narrowShotKey].
Widget narrowShotBoundary(Widget app) =>
    RepaintBoundary(key: narrowShotKey, child: app);

/// Loads the app's bundled fonts (and the Material icons of the SDK when
/// found), so text is measured and drawn as on a device, not in the 1 em
/// test font. Call from `setUpAll`.
Future<void> loadAppFonts() async {
  const families = {
    'GolosText': ['400', '500', '600', '700'],
    'Manrope': ['700', '800'],
  };
  for (final entry in families.entries) {
    final loader = FontLoader(entry.key);
    for (final weight in entry.value) {
      loader.addFont(_fontData('assets/fonts/${entry.key}-$weight.ttf'));
    }
    await loader.load();
  }
  final root = Platform.environment['FLUTTER_ROOT'];
  final icons = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (root != null && icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(_fontData(icons.path))).load();
  }
}

Future<ByteData> _fontData(String path) async =>
    ByteData.sublistView(await File(path).readAsBytes());

/// Puts the app into [cell]: screen, text scale, locale and senior mode.
Future<void> applyNarrowCell(
  WidgetTester tester,
  ProviderContainer container,
  NarrowCell cell,
) async {
  tester.view.devicePixelRatio = _shotPixelRatio;
  tester.view.physicalSize = cell.size * _shotPixelRatio;
  tester.platformDispatcher.textScaleFactorTestValue = cell.scale;
  container.read(settingsProvider.notifier)
    ..setLocale(cell.locale)
    ..setSeniorMode(enabled: cell.senior);
  await settleNarrow(tester);
}

/// A few frames and the theme and route animations: the app keeps timers
/// and spinners, so `pumpAndSettle` may never return.
Future<void> settleNarrow(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Problems found on one screen, in order: [failures] fail the test,
/// [notes] are reported only (squeezed text where the text is so large that
/// a word may be wider than its column whatever the layout).
class NarrowFindings {
  final List<String> _failures = [];
  final List<String> _notes = [];
  final Set<String> _seen = {};

  /// What fails the test.
  List<String> get failures => List.unmodifiable(_failures);

  /// What is only reported.
  List<String> get notes => List.unmodifiable(_notes);

  /// Adds [finding] once; returns whether it was new.
  bool add(String finding, {required bool failing}) {
    if (!_seen.add(finding)) {
      return false;
    }
    (failing ? _failures : _notes).add(finding);
    return true;
  }
}

/// Checks every page of the current screen of [screen] in [cell]; returns
/// whether something new was found. Squeezed text fails only where
/// [strict]; an exception (a layout overflow) always does. Writes
/// screenshots when [narrowShotsDir] is set and [shoot] says so (or
/// something was found).
Future<bool> checkNarrowScreen(
  WidgetTester tester,
  String screen,
  NarrowCell cell,
  NarrowFindings findings, {
  required bool shoot,
  required bool strict,
}) async {
  var found = false;
  final scrollable = _mainScrollable(tester);
  scrollable?.position.jumpTo(0);
  await tester.pump();
  for (var page = 0; page < _maxPages; page++) {
    final pageFound = _collect(
      tester,
      '$screen ${cell.label}',
      cell,
      findings,
      strict: strict,
    );
    found |= pageFound;
    if (shoot || pageFound) {
      await _shoot(tester, screen, '${cell.label}-p$page');
    }
    final position = scrollable?.position;
    if (position == null || position.pixels >= position.maxScrollExtent) {
      break;
    }
    position.jumpTo(
      math.min(
        position.maxScrollExtent,
        position.pixels + position.viewportDimension * 0.8,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
  return found;
}

bool _collect(
  WidgetTester tester,
  String where,
  NarrowCell cell,
  NarrowFindings findings, {
  required bool strict,
}) {
  var found = false;
  final error = tester.takeException();
  if (error != null) {
    final first = error.toString().split('\n').first;
    found |= findings.add('$where: exception: $first', failing: true);
  }
  for (final element in find.byType(RichText).evaluate()) {
    if (!_inCurrentRoute(element)) {
      continue;
    }
    final paragraph = element.renderObject;
    if (paragraph is! RenderParagraph || !paragraph.hasSize) {
      continue;
    }
    final squeeze = squeezeOf(paragraph, cell.size.width);
    if (squeeze != null) {
      found |= findings.add('$where: $squeeze', failing: strict);
    }
  }
  return found;
}

/// Why [paragraph] is squeezed, or null when it reads fine on a screen
/// [screenWidth] wide.
///
/// Squeezed: a text of [_minSqueezeLength] or more characters that is laid
/// out narrower than its longest word (the word breaks inside) although
/// the word fits the screen less its side paddings, or that is narrower than
/// two of its em while it wraps. Texts cut with an ellipsis or a fade, or
/// kept on one line, are truncation, accepted where the screen chose it; a
/// text with an inline widget (a field in a sentence) is not measured.
String? squeezeOf(RenderParagraph paragraph, double screenWidth) {
  final text = paragraph.text.toPlainText().trim();
  if (text.length < _minSqueezeLength ||
      text.contains('\uFFFC') ||
      paragraph.maxLines == 1 ||
      paragraph.overflow == TextOverflow.ellipsis ||
      paragraph.overflow == TextOverflow.fade ||
      !paragraph.softWrap) {
    return null;
  }
  final width = paragraph.size.width;
  final longestWord = paragraph.getMinIntrinsicWidth(double.infinity);
  final fontSize = paragraph.textScaler.scale(
    paragraph.text.style?.fontSize ?? _defaultFontSize(paragraph),
  );
  final wraps = paragraph.size.height > fontSize * 2;
  final breaksWord = width + 1 < longestWord &&
      longestWord <= screenWidth - 2 * PillPalSpacing.lg;
  final tooNarrow = wraps && width < fontSize * 2;
  if (!breaksWord && !tooNarrow) {
    return null;
  }
  final shown = text.length > 40 ? '${text.substring(0, 40)}…' : text;
  return 'squeezed "$shown" (width ${width.toStringAsFixed(0)}, '
      'longest word ${longestWord.toStringAsFixed(0)})';
}

double _defaultFontSize(RenderParagraph paragraph) {
  var size = 14.0;
  paragraph.text.visitChildren((span) {
    final fontSize = span.style?.fontSize;
    if (fontSize != null) {
      size = fontSize;
      return false;
    }
    return true;
  });
  return size;
}

bool _inCurrentRoute(Element element) {
  final route = ModalRoute.of(element);
  return route == null || route.isCurrent;
}

/// The vertical scrollable of the current route with the tallest viewport.
ScrollableState? _mainScrollable(WidgetTester tester) {
  ScrollableState? best;
  for (final element in find.byType(Scrollable).evaluate()) {
    final state = (element as StatefulElement).state;
    if (state is! ScrollableState ||
        state.widget.axisDirection != AxisDirection.down ||
        !_inCurrentRoute(element) ||
        !state.position.hasViewportDimension) {
      continue;
    }
    final height = state.position.viewportDimension;
    if (best == null || height > best.position.viewportDimension) {
      best = state;
    }
  }
  return best;
}

Future<void> _shoot(WidgetTester tester, String screen, String name) async {
  final dir = narrowShotsDir;
  final boundary = find.byKey(narrowShotKey);
  if (dir == null || boundary.evaluate().isEmpty) {
    return;
  }
  final render = tester.renderObject<RenderRepaintBoundary>(boundary);
  await tester.runAsync(() async {
    final image = await render.toImage(pixelRatio: _shotPixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File('$dir/$screen/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

/// Appends [findings] of [screen] to `findings.txt` in [narrowShotsDir].
Future<void> writeNarrowFindings(
  WidgetTester tester,
  String screen,
  NarrowFindings findings,
) async {
  final dir = narrowShotsDir;
  if (dir == null) {
    return;
  }
  await tester.runAsync(() async {
    final file = File('$dir/findings.txt');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '## $screen (${findings.failures.length} failing, '
      '${findings.notes.length} notes)\n'
      '${findings.failures.map((f) => 'FAIL $f\n').join()}'
      '${findings.notes.map((f) => 'note $f\n').join()}',
      mode: FileMode.append,
    );
  });
}

/// Pumps the app on [container] inside the screenshot boundary.
Future<void> pumpNarrowApp(
  WidgetTester tester,
  ProviderContainer container,
) async {
  tester.view.devicePixelRatio = _shotPixelRatio;
  tester.view.physicalSize = narrowSizes[1] * _shotPixelRatio;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: narrowShotBoundary(const PillPalApp()),
    ),
  );
  await settleNarrow(tester);
}
