import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/theme/palette.dart';

/// The Android launch window shows the palette `background` before the first
/// Flutter frame (docs/design.md); the XML resources mirror it.
Color _launchColor(String values) {
  final xml =
      File('android/app/src/main/res/$values/colors.xml').readAsStringSync();
  final match = RegExp(
    r'<color name="launch_background">(#[0-9A-Fa-f]{8})</color>',
  ).firstMatch(xml);
  expect(match, isNotNull, reason: '$values/colors.xml has launch_background');
  return Color(int.parse(match!.group(1)!.substring(1), radix: 16));
}

void main() {
  test('launch background is the light palette bg', () {
    expect(_launchColor('values'), PillPalPalette.light.background);
  });

  test('launch background is the dark palette bg at night', () {
    expect(_launchColor('values-night'), PillPalPalette.dark.background);
  });

  test('both launch drawables and window backgrounds use that colour', () {
    const res = 'android/app/src/main/res';
    for (final file in [
      '$res/drawable/launch_background.xml',
      '$res/drawable-v21/launch_background.xml',
    ]) {
      expect(
        File(file).readAsStringSync(),
        contains('@color/launch_background'),
        reason: file,
      );
    }
    for (final values in ['values', 'values-night']) {
      final styles = File('$res/$values/styles.xml').readAsStringSync();
      expect(
        RegExp('@color/launch_background').allMatches(styles).length,
        1,
        reason: '$values/styles.xml NormalTheme',
      );
    }
  });
}
