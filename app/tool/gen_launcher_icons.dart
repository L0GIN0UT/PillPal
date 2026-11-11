// Regenerates the legacy launcher PNGs (API 24-25) from the brand SVG.
//
// Pure Dart, no packages: it parses the single `d` attribute of
// docs/design/brand/pillpal_monogram.svg (M/H/V/C/Z, absolute), flattens it,
// fills it with the even-odd rule (8x8 supersampling) over a rounded tile in
// the palette background colour and writes RGBA PNGs.
//
// Usage, from any directory: dart run app/tool/gen_launcher_icons.dart
// (paths are resolved from this script's location).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

typedef _Polygon = List<math.Point<double>>;

const _densities = <String, int>{
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};
const _ink = [0x29, 0x3F, 0x3C];
const _background = [0xF2, 0xF6, 0xF5];
const _glyphShare = 0.62; // glyph height / tile size
const _tileRadiusShare = 0.22;
const _supersample = 8;
const _curveSteps = 32;

void main() {
  final appDir = File.fromUri(Platform.script).parent.parent.path;
  final svgFile = File('$appDir/../docs/design/brand/pillpal_monogram.svg');
  final d = RegExp(r'\sd="([^"]*)"').firstMatch(svgFile.readAsStringSync());
  if (d == null) {
    stderr.writeln('No path "d" attribute found in ${svgFile.path}');
    exitCode = 1;
    return;
  }
  final polygons = _flatten(d.group(1)!);
  _densities.forEach((name, size) {
    final dir = Directory('$appDir/android/app/src/main/res/mipmap-$name')
      ..createSync(recursive: true);
    File(
      '${dir.path}/ic_launcher.png',
    ).writeAsBytesSync(_png(size, _render(size, polygons)));
    stdout.writeln('mipmap-$name/ic_launcher.png ${size}px');
  });
}

/// Numbers per path command.
const _arity = {'M': 2, 'H': 1, 'V': 1, 'C': 6, 'Z': 0};

List<_Polygon> _flatten(String d) {
  final tokens = RegExp(
    r'[MHVCZ]|-?\d+(?:\.\d+)?',
  ).allMatches(d).map((m) => m.group(0)!).toList();
  final polygons = <_Polygon>[];
  var current = <math.Point<double>>[];
  var pen = const math.Point<double>(0, 0);
  var i = 0;
  while (i < tokens.length) {
    final op = tokens[i++];
    final arity = _arity[op];
    if (arity == null) throw FormatException('unexpected token $op');
    final a = [for (var k = 0; k < arity; k++) double.parse(tokens[i++])];
    switch (op) {
      case 'M':
        pen = math.Point(a[0], a[1]);
        current = [pen];
      case 'H':
        pen = math.Point(a[0], pen.y);
        current.add(pen);
      case 'V':
        pen = math.Point(pen.x, a[0]);
        current.add(pen);
      case 'C':
        current.addAll(_cubic(pen, a));
        pen = math.Point(a[4], a[5]);
      default:
        polygons.add(current);
    }
  }
  return polygons;
}

/// Points of the cubic from [p0] with control numbers [c] (x1 y1 x2 y2 x3 y3).
Iterable<math.Point<double>> _cubic(
  math.Point<double> p0,
  List<double> c,
) sync* {
  double at(double t, double v0, double v1, double v2, double v3) {
    final u = 1 - t;
    return u * u * u * v0 +
        3 * u * u * t * v1 +
        3 * u * t * t * v2 +
        t * t * t * v3;
  }

  for (var s = 1; s <= _curveSteps; s++) {
    final t = s / _curveSteps;
    yield math.Point(
      at(t, p0.x, c[0], c[2], c[4]),
      at(t, p0.y, c[1], c[3], c[5]),
    );
  }
}

/// Returns RGBA bytes of a [size] x [size] icon.
Uint8List _render(int size, List<_Polygon> polygons) {
  final edges = _edgesInSubpixels(size, polygons);
  final glyph = List<int>.filled(size * size, 0);
  final tile = List<int>.filled(size * size, 0);
  _fill(size, edges, glyph, tile);
  return _composite(size, glyph, tile);
}

/// Polygon edges scaled so the glyph is [_glyphShare] of the tile and its
/// bounding box is centred; the box is derived from the polygons.
List<List<double>> _edgesInSubpixels(int size, List<_Polygon> polygons) {
  final points = [for (final p in polygons) ...p];
  final minX = points.map((p) => p.x).reduce(math.min);
  final maxX = points.map((p) => p.x).reduce(math.max);
  final minY = points.map((p) => p.y).reduce(math.min);
  final maxY = points.map((p) => p.y).reduce(math.max);
  final n = size * _supersample;
  final scale = n * _glyphShare / (maxY - minY);
  double fx(double v) => (v - (minX + maxX) / 2) * scale + n / 2;
  double fy(double v) => (v - (minY + maxY) / 2) * scale + n / 2;
  return [
    for (final p in polygons)
      for (var k = 0; k < p.length; k++)
        [
          fx(p[k].x),
          fy(p[k].y),
          fx(p[(k + 1) % p.length].x),
          fy(p[(k + 1) % p.length].y),
        ],
  ];
}

/// Counts, per pixel, the sub-samples inside the glyph and inside the tile.
void _fill(
  int size,
  List<List<double>> edges,
  List<int> glyph,
  List<int> tile,
) {
  final n = size * _supersample;
  final radius = n * _tileRadiusShare;
  for (var sy = 0; sy < n; sy++) {
    final yc = sy + 0.5;
    final xs = <double>[];
    for (final e in edges) {
      if ((e[1] <= yc) != (e[3] <= yc)) {
        xs.add(e[0] + (yc - e[1]) / (e[3] - e[1]) * (e[2] - e[0]));
      }
    }
    xs.sort();
    for (var sx = 0; sx < n; sx++) {
      final xc = sx + 0.5;
      final px = (sy ~/ _supersample) * size + sx ~/ _supersample;
      if (xs.where((x) => x <= xc).length.isOdd) glyph[px]++;
      final dx = math.max(0.0, math.max(radius - xc, xc - (n - radius)));
      final dy = math.max(0.0, math.max(radius - yc, yc - (n - radius)));
      if (dx * dx + dy * dy <= radius * radius) tile[px]++;
    }
  }
}

Uint8List _composite(int size, List<int> glyph, List<int> tile) {
  final out = Uint8List(size * size * 4);
  const total = _supersample * _supersample;
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
