import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/theme/brand/pillpal_monogram.dart';

/// The path tokens of [data], whatever the white space.
List<String> _tokens(String data) => RegExp(
      r'[MHVCZ]|-?\d+(?:\.\d+)?',
    ).allMatches(data).map((match) => match.group(0)!).toList();

String _attribute(String file, String name) {
  final text = File(file).readAsStringSync();
  return RegExp('$name="([^"]*)"').firstMatch(text)!.group(1)!;
}

bool _inside(Size size, Rect bounds) =>
    (Offset.zero & size).contains(bounds.topLeft) &&
    (Offset.zero & size).contains(bounds.bottomRight);

void main() {
  const size = Size(350, 350);

  test('the path stays inside the canvas and has even-odd fill', () {
    final path = PillPalMonogramPainter.pathFor(size);
    final bounds = path.getBounds();
    expect(path.fillType, PathFillType.evenOdd);
    expect(_inside(size, bounds), isTrue);
    // The glyph spans 119..387 x 101..399 of the viewBox 80 75 350 350.
    expect(bounds.left, closeTo(39, 0.01));
    expect(bounds.top, closeTo(26, 0.01));
    expect(bounds.right, closeTo(307, 0.01));
    expect(bounds.bottom, closeTo(324, 0.01));
  });

  test('the bowl of the P is a hole and the stroke is filled', () {
    final path = PillPalMonogramPainter.pathFor(size);
    // SVG (300, 160) is inside the bowl, (132, 200) is in the left stroke.
    expect(path.contains(const Offset(300 - 80, 160 - 75)), isFalse);
    expect(path.contains(const Offset(132 - 80, 200 - 75)), isTrue);
  });

  test('the path scales uniformly and centres in a non-square box', () {
    const wide = Size(200, 100);
    final bounds = PillPalMonogramPainter.pathFor(wide).getBounds();
    expect(_inside(wide, bounds), isTrue);
    // The viewBox is centred: 50 units of slack left, glyph starts at 39.
    expect(bounds.left, closeTo(50 + 39 * 100 / 350, 0.01));
    // Scale = 100 / 350: the glyph is 298 units tall.
    expect(bounds.height, closeTo(298 * 100 / 350, 0.01));
  });

  test('the Dart path data is the path of the brand SVG', () {
    final svgData = _attribute(
      '../docs/design/brand/pillpal_monogram.svg',
      r'\sd',
    );
    expect(_tokens(pillPalMonogramPathData), _tokens(svgData));
  });

  test('the Android vectors carry the same path', () {
    final expected = _tokens(pillPalMonogramPathData);
    for (final name in [
      'ic_launcher_foreground',
      'ic_launcher_monochrome',
      'ic_stat_pillpal',
    ]) {
      final data = _attribute(
        'android/app/src/main/res/drawable/$name.xml',
        r'android:pathData',
      );
      expect(_tokens(data), expected, reason: name);
    }
  });

  test('the notification icon is the kept small icon', () {
    final keep = File(
      'android/app/src/main/res/raw/keep.xml',
    ).readAsStringSync();
    expect(keep, contains('@drawable/ic_stat_pillpal'));
    final source = File(
      'lib/src/reminders/flutter_notification_scheduler.dart',
    ).readAsStringSync();
    expect(source, contains("_androidIcon = 'ic_stat_pillpal'"));
  });

  testWidgets('the widget paints in the colour it is given', (tester) async {
    const color = Color(0xFF123456);
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox.square(
            dimension: 40,
            child: PillPalMonogram(color: color),
          ),
        ),
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(PillPalMonogram),
        matching: find.byType(CustomPaint),
      ),
    );
    final painter = paint.painter! as PillPalMonogramPainter;
    expect(painter.color, color);
    expect(
      painter.shouldRepaint(const PillPalMonogramPainter(color: color)),
      isFalse,
    );
    expect(
      painter.shouldRepaint(
        const PillPalMonogramPainter(color: Color(0xFF000000)),
      ),
      isTrue,
    );
  });
}
