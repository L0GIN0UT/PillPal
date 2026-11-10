import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

/// The code points a TrueType font maps to a glyph (`cmap` formats 4 and 12).
Set<int> _mappedCodePoints(String path) {
  final data = ByteData.sublistView(File(path).readAsBytesSync());
  final tables = data.getUint16(4);
  var cmap = -1;
  for (var i = 0; i < tables; i++) {
    final record = 12 + 16 * i;
    final tag = String.fromCharCodes(
      [for (var k = 0; k < 4; k++) data.getUint8(record + k)],
    );
    if (tag == 'cmap') {
      cmap = data.getUint32(record + 8);
    }
  }
  expect(cmap, isNonNegative, reason: '$path has no cmap');
  final mapped = <int>{};
  final subtables = data.getUint16(cmap + 2);
  for (var i = 0; i < subtables; i++) {
    final offset = cmap + data.getUint32(cmap + 4 + 8 * i + 4);
    switch (data.getUint16(offset)) {
      case 4:
        _readFormat4(data, offset, mapped);
      case 12:
        _readFormat12(data, offset, mapped);
    }
  }
  return mapped;
}

void _readFormat4(ByteData data, int base, Set<int> mapped) {
  final segments = data.getUint16(base + 6) ~/ 2;
  final ends = base + 14;
  final starts = ends + 2 * segments + 2;
  final deltas = starts + 2 * segments;
  final ranges = deltas + 2 * segments;
  for (var i = 0; i < segments; i++) {
    final start = data.getUint16(starts + 2 * i);
    final end = data.getUint16(ends + 2 * i);
    final rangeOffset = data.getUint16(ranges + 2 * i);
    for (var c = start; c <= end && c != 0xFFFF; c++) {
      var glyph = 0;
      if (rangeOffset == 0) {
        glyph = (c + data.getInt16(deltas + 2 * i)) & 0xFFFF;
      } else {
        final at = ranges + 2 * i + rangeOffset + 2 * (c - start);
        glyph = data.getUint16(at);
      }
      if (glyph != 0) {
        mapped.add(c);
      }
    }
  }
}

void _readFormat12(ByteData data, int base, Set<int> mapped) {
  final groups = data.getUint32(base + 12);
  for (var i = 0; i < groups; i++) {
    final group = base + 16 + 12 * i;
    final start = data.getUint32(group);
    final end = data.getUint32(group + 4);
    for (var c = start; c <= end; c++) {
      mapped.add(c);
    }
  }
}

/// Cyrillic А-я and Ёё, digits, basic punctuation, and the signs a report
/// or a dose line can carry: № ₽ € x degree, minus and NBSP.
Set<int> _requiredGlyphs({required bool text}) => {
      for (var c = 0x30; c <= 0x39; c++) c,
      if (text) ...[
        for (var c = 0x410; c <= 0x44F; c++) c,
        0x401,
        0x451,
        for (final ch in """.,:;!?-()'%/+= """.runes) ch,
        0x2116,
        0x20BD,
        0x20AC,
        0xD7,
        0xB0,
        0x2212,
        0xA0,
      ],
    };

/// Every (family, weight) a theme slot can ask for.
Set<(String, int)> _usedFaces(ThemeData theme) {
  final styles = <TextStyle?>[
    theme.textTheme.displayLarge,
    theme.textTheme.displayMedium,
    theme.textTheme.displaySmall,
    theme.textTheme.headlineLarge,
    theme.textTheme.headlineMedium,
    theme.textTheme.headlineSmall,
    theme.textTheme.titleLarge,
    theme.textTheme.titleMedium,
    theme.textTheme.titleSmall,
    theme.textTheme.bodyLarge,
    theme.textTheme.bodyMedium,
    theme.textTheme.bodySmall,
    theme.textTheme.labelLarge,
    theme.textTheme.labelMedium,
    theme.textTheme.labelSmall,
    theme.textTheme.numeral,
    theme.navigationBarTheme.labelTextStyle?.resolve({}),
    theme.navigationBarTheme.labelTextStyle?.resolve({WidgetState.selected}),
    theme.segmentedButtonTheme.style?.textStyle?.resolve({}),
    theme.segmentedButtonTheme.style?.textStyle
        ?.resolve({WidgetState.selected}),
    theme.chipTheme.labelStyle,
    theme.appBarTheme.titleTextStyle,
  ];
  return {
    for (final style in styles)
      if (style != null) (style.fontFamily!, style.fontWeight!.value),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every face a theme slot uses is declared in pubspec', () {
    final declared = _declaredFonts().weights;
    for (final brightness in Brightness.values) {
      final theme = buildPillPalTheme(brightness: brightness, senior: false);
      for (final (family, weight) in _usedFaces(theme)) {
        expect(declared[family], contains(weight), reason: '$family $weight');
      }
    }
  });

  test('Golos Text covers Cyrillic, digits, punctuation and signs', () {
    for (final weight in [400, 500, 600, 700]) {
      final path = 'assets/fonts/GolosText-$weight.ttf';
      final mapped = _mappedCodePoints(path);
      final missing = _requiredGlyphs(text: true).difference(mapped);
      expect(missing, isEmpty, reason: '$path misses $missing');
    }
  });

  test('Manrope covers the digits of times and counters', () {
    for (final weight in [700, 800]) {
      final path = 'assets/fonts/Manrope-$weight.ttf';
      final missing =
          _requiredGlyphs(text: false).difference(_mappedCodePoints(path));
      expect(missing, isEmpty, reason: '$path misses $missing');
    }
  });

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
