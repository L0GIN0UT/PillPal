import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/font_licenses.dart';

/// `family -> asset paths` and `family -> weights` from the `fonts:` block of
/// pubspec.yaml (a line scan: the app has no YAML dependency).
({Map<String, List<String>> assets, Map<String, List<int>> weights})
    _declaredFonts() {
  final assets = <String, List<String>>{};
  final weights = <String, List<int>>{};
  String? family;
  for (final line in File('pubspec.yaml').readAsLinesSync()) {
    final familyMatch = RegExp(r'^\s*-\s*family:\s*(\S+)').firstMatch(line);
    if (familyMatch != null) {
      family = familyMatch.group(1);
      assets[family!] = [];
      weights[family] = [];
      continue;
    }
    final asset = RegExp(r'asset:\s*(\S+\.ttf)').firstMatch(line);
    if (family != null && asset != null) {
      assets[family]!.add(asset.group(1)!);
    }
    final weight = RegExp(r'^\s*weight:\s*(\d+)').firstMatch(line);
    if (family != null && weight != null) {
      weights[family]!.add(int.parse(weight.group(1)!));
    }
  }
  return (assets: assets, weights: weights);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pubspec declares exactly the PillPalFonts families', () {
    final fonts = _declaredFonts();
    expect(
      fonts.assets.keys.toSet(),
      {PillPalFonts.display, PillPalFonts.body},
    );
  });

  test('Manrope has 700/800 and Golos Text 400/500/600/700', () {
    final fonts = _declaredFonts();
    expect(fonts.weights[PillPalFonts.display], [700, 800]);
    expect(fonts.weights[PillPalFonts.body], [400, 500, 600, 700]);
  });

  test('every declared font file and licence text exists', () {
    final fonts = _declaredFonts();
    for (final path in fonts.assets.values.expand((files) => files)) {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: path);
      expect(file.lengthSync(), greaterThan(10000), reason: path);
    }
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final licence in fontLicenseAssets) {
      expect(File(licence).existsSync(), isTrue, reason: licence);
      expect(pubspec, contains(licence), reason: licence);
    }
  });

  test('Rubik and Nunito are gone from lib and assets', () {
    final old = RegExp('Rubik|Nunito');
    for (final root in ['lib', 'assets']) {
      for (final entity in Directory(root).listSync(recursive: true)) {
        if (entity is! File) {
          continue;
        }
        expect(old.hasMatch(entity.path), isFalse, reason: entity.path);
        if (entity.path.endsWith('.dart') || entity.path.endsWith('.txt')) {
          expect(
            old.hasMatch(entity.readAsStringSync()),
            isFalse,
            reason: entity.path,
          );
        }
      }
    }
    expect(old.hasMatch(File('pubspec.yaml').readAsStringSync()), isFalse);
  });

  test('the OFL texts reach the licence registry', () async {
    registerFontLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    final packages = entries.expand((entry) => entry.packages).toSet();
    expect(packages, containsAll(['Manrope', 'GolosText']));
    final manrope = entries.firstWhere(
      (entry) => entry.packages.contains('Manrope'),
    );
    final text =
        manrope.paragraphs.map((paragraph) => paragraph.text).join('\n');
    expect(text, contains('SIL OPEN FONT LICENSE'));
  });
}
