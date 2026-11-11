import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/reminders/flutter_notification_scheduler.dart';
import 'package:pillpal/src/reminders/reminder_accent.dart';
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

  group('Android vectors', () {
    const res = 'android/app/src/main/res';
    // name, fill, canvas dp, the box the transformed glyph must stay in.
    final variants = <(String, String, double, Rect)>[
      // The adaptive safe zone is the central 66 dp of 108.
      (
        'ic_launcher_foreground',
        '#FF293F3C',
        108,
        const Rect.fromLTWH(21, 21, 66, 66),
      ),
      (
        'ic_launcher_monochrome',
        '#FF000000',
        108,
        const Rect.fromLTWH(21, 21, 66, 66),
      ),
      ('ic_stat_pillpal', '#FFFFFFFF', 24, const Rect.fromLTWH(0, 0, 24, 24)),
    ];

    for (final (name, fill, canvas, box) in variants) {
      test('$name: same path, even-odd, $fill, glyph inside its box', () {
        final file = '$res/drawable/$name.xml';
        expect(
          _tokens(_attribute(file, r'android:pathData')),
          _tokens(pillPalMonogramPathData),
        );
        expect(_attribute(file, r'android:fillType'), 'evenOdd');
        expect(_attribute(file, r'android:fillColor'), fill);
        expect(_attribute(file, r'android:viewportWidth'), '${canvas.toInt()}');

        final scale = double.parse(_attribute(file, r'android:scaleX'));
        expect(double.parse(_attribute(file, r'android:scaleY')), scale);
        final tx = double.parse(_attribute(file, r'android:translateX'));
        final ty = double.parse(_attribute(file, r'android:translateY'));
        // Raw glyph bounds: the path at scale 1 is shifted by the viewBox.
        final raw = PillPalMonogramPainter.pathFor(const Size(350, 350))
            .getBounds()
            .shift(
              Offset(pillPalMonogramViewBox.left, pillPalMonogramViewBox.top),
            );
        final glyph = Rect.fromLTRB(
          raw.left * scale + tx,
          raw.top * scale + ty,
          raw.right * scale + tx,
          raw.bottom * scale + ty,
        );
        expect(box.contains(glyph.topLeft), isTrue, reason: '$glyph');
        expect(box.contains(glyph.bottomRight), isTrue, reason: '$glyph');
      });
    }
  });

  test('legacy launcher PNGs are valid and have the density sizes', () {
    const sizes = {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    };
    sizes.forEach((density, size) {
      final bytes = File(
        'android/app/src/main/res/mipmap-$density/ic_launcher.png',
      ).readAsBytesSync();
      expect(bytes.sublist(0, 8), [
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ]);
      final header = ByteData.sublistView(bytes, 16, 24);
      expect(header.getUint32(0), size, reason: density);
      expect(header.getUint32(4), size, reason: density);
    });
  });

  test(
    'the reminder icon exists, is kept from shrinking and is native-used',
    () {
      expect(androidReminderIconName, 'ic_stat_pillpal');
      expect(
        File(
          'android/app/src/main/res/drawable/$androidReminderIconName.xml',
        ).existsSync(),
        isTrue,
      );
      expect(
        File('android/app/src/main/res/raw/keep.xml').readAsStringSync(),
        contains('@drawable/$androidReminderIconName'),
      );
    },
  );

  test('the native alerts plugin uses the same icon and accent', () {
    final java = File(
      '../packages/pillpal_alerts/android/src/main/java/com/pillpal/alerts/'
      'AlertsPlugin.java',
    ).readAsStringSync();
    expect(java, contains('SMALL_ICON_NAME = "$androidReminderIconName"'));
    expect(java, contains('getIdentifier(SMALL_ICON_NAME, "drawable"'));
    expect(java, contains('.setColor(ACCENT_COLOR)'));
    final hex = reminderAccent.toARGB32().toRadixString(16).toUpperCase();
    expect(java, contains('ACCENT_COLOR = 0x$hex;'));
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

  testWidgets('the monogram is decorative (no semantics)', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox.square(
          dimension: 40,
          child: PillPalMonogram(color: Color(0xFF123456)),
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(PillPalMonogram),
        matching: find.byType(ExcludeSemantics),
      ),
      findsOneWidget,
    );
  });
}
