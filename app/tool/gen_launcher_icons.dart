// Regenerates the legacy launcher PNGs (API 24-25) from the brand SVG.
//
// Pure Dart, no packages: it parses the single `d` attribute of
// docs/design/brand/pillpal_monogram.svg (M/H/V/C/Z, absolute), flattens it,
// fills it with the even-odd rule (8x8 supersampling) over a rounded tile in
// the palette background colour and writes RGBA PNGs.
//
// Usage (repo root or app/): dart run tool/gen_launcher_icons.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const _svgPath = '../docs/design/brand/pillpal_monogram.svg';
const _resDir = 'android/app/src/main/res';
const _densities = <String, int>{
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};
const _ink = [0x29, 0x3F, 0x3C];
const _background = [0xF2, 0xF6, 0xF5];
// Glyph bounds in SVG units: x 119..387, y 101..399.
const _glyphCenterX = 253.0;
const _glyphCenterY = 250.0;
const _glyphHeight = 298.0;
const _glyphShare = 0.62; // glyph height / tile size
const _tileRadiusShare = 0.22;
const _supersample = 8;
const _curveSteps = 32;

void main() {
  final svg = File(_svgPath).readAsStringSync();
  final d = RegExp(r'\sd="([^"]*)"').firstMatch(svg)!.group(1)!;
  final polygons = _flatten(d);
  _densities.forEach((name, size) {
    final png = _png(size, _render(size, polygons));
    final dir = Directory('$_resDir/mipmap-$name')..createSync(recursive: true);
    File('${dir.path}/ic_launcher.png').writeAsBytesSync(png);
    stdout.writeln('mipmap-$name/ic_launcher.png ${size}px');
  });
}

List<List<math.Point<double>>> _flatten(String d) {
  final tokens = RegExp(
    r'[MHVCZ]|-?\d+(?:\.\d+)?',
  ).allMatches(d).map((m) => m.group(0)!).toList();
  final polygons = <List<math.Point<double>>>[];
  var current = <math.Point<double>>[];
  var x = 0.0, y = 0.0, i = 0;
  double num() => double.parse(tokens[i++]);
  while (i < tokens.length) {
    final cmd = tokens[i++];
    switch (cmd) {
      case 'M':
        x = num();
        y = num();
        current = [math.Point(x, y)];
      case 'H':
        x = num();
        current.add(math.Point(x, y));
      case 'V':
        y = num();
        current.add(math.Point(x, y));
      case 'C':
        final c = [for (var k = 0; k < 6; k++) num()];
        for (var s = 1; s <= _curveSteps; s++) {
          final t = s / _curveSteps, u = 1 - t;
          double b(double p0, double p1, double p2, double p3) =>
              u * u * u * p0 +
              3 * u * u * t * p1 +
              3 * u * t * t * p2 +
              t * t * t * p3;
          current.add(
            math.Point(b(x, c[0], c[2], c[4]), b(y, c[1], c[3], c[5])),
          );
        }
        x = c[4];
        y = c[5];
      case 'Z':
        polygons.add(current);
      default:
        throw FormatException('unexpected token $cmd');
    }
  }
  return polygons;
}

/// Returns RGBA bytes of a [size] x [size] icon.
Uint8List _render(int size, List<List<math.Point<double>>> polygons) {
  final scale = size * _glyphShare / _glyphHeight;
  final ss = _supersample, n = size * ss;
  // Polygon edges in sub-pixel space.
  final edges = <List<double>>[];
  for (final p in polygons) {
    for (var k = 0; k < p.length; k++) {
      final a = p[k], b = p[(k + 1) % p.length];
      double fx(double v) => (v - _glyphCenterX) * scale * ss + n / 2;
      double fy(double v) => (v - _glyphCenterY) * scale * ss + n / 2;
      edges.add([fx(a.x), fy(a.y), fx(b.x), fy(b.y)]);
    }
  }
  final glyph = List<int>.filled(size * size, 0);
  final tile = List<int>.filled(size * size, 0);
  final radius = size * ss * _tileRadiusShare;
  for (var sy = 0; sy < n; sy++) {
    final yc = sy + 0.5;
    final xs = <double>[];
    for (final e in edges) {
      final (x0, y0, x1, y1) = (e[0], e[1], e[2], e[3]);
      if ((y0 <= yc) != (y1 <= yc)) {
        xs.add(x0 + (yc - y0) / (y1 - y0) * (x1 - x0));
      }
    }
    xs.sort();
    for (var sx = 0; sx < n; sx++) {
      final xc = sx + 0.5;
      var crossings = 0;
      for (final cx in xs) {
        if (cx <= xc) crossings++;
      }
      final px = (sy ~/ ss) * size + sx ~/ ss;
      if (crossings.isOdd) glyph[px]++;
      final dx = math.max(0.0, math.max(radius - xc, xc - (n - radius)));
      final dy = math.max(0.0, math.max(radius - yc, yc - (n - radius)));
      if (dx * dx + dy * dy <= radius * radius) tile[px]++;
    }
  }
  final out = Uint8List(size * size * 4);
  final total = ss * ss;
  for (var px = 0; px < size * size; px++) {
    final g = glyph[px], r = math.max(tile[px], g);
    if (r == 0) continue;
    for (var c = 0; c < 3; c++) {
      out[px * 4 + c] = ((g * _ink[c] + (r - g) * _background[c]) / r).round();
    }
    out[px * 4 + 3] = (255 * r / total).round();
  }
  return out;
}

Uint8List _png(int size, Uint8List rgba) {
  final raw = BytesBuilder();
  for (var row = 0; row < size; row++) {
    raw.addByte(0);
    raw.add(rgba.sublist(row * size * 4, (row + 1) * size * 4));
  }
  final out = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final body = [...type.codeUnits, ...data];
    out
      ..add(_u32(data.length))
      ..add(body)
      ..add(_u32(_crc32(body)));
  }

  chunk('IHDR', [..._u32(size), ..._u32(size), 8, 6, 0, 0, 0]);
  chunk('IDAT', ZLibEncoder(level: 9).convert(raw.toBytes()));
  chunk('IEND', const []);
  return out.toBytes();
}

List<int> _u32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
