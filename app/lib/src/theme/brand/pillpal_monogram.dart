import 'package:flutter/widgets.dart';

/// Brand asset: the PillPal "P" monogram, `docs/design/brand/
/// pillpal_monogram.svg`. The path data below is that file's `d` attribute
/// and `test/theme/pillpal_monogram_test.dart` keeps them equal. Commands are
/// absolute `M H V C Z` only, so no SVG package is needed.
const String pillPalMonogramPathData = '''
M 154 101 H 297 C 347 101 387 141 387 196 C 387 250 346 294 295 294 H 256
V 333 C 256 370 225 399 188 399 C 150 399 119 370 119 335 V 140
C 119 119 134 101 154 101 Z
M 158 127 C 150 127 145 133 145 141 V 333 C 145 356 164 373 187 373
C 212 373 231 355 231 331 V 295 H 206 C 184 295 167 277 167 255 V 205
H 217 C 240 205 257 223 257 247 V 269 H 295 C 334 269 362 237 362 196
C 362 157 334 127 297 127 Z
M 193 231 H 211 C 223 231 231 239 231 251 V 269 H 210
C 200 269 193 261 193 251 Z
''';

/// The SVG `viewBox` (`80 75 350 350`) the path data lives in.
const Rect pillPalMonogramViewBox = Rect.fromLTWH(80, 75, 350, 350);

/// One absolute path command: `M H V C` with its numbers, or `Z`.
typedef _Command = ({String op, List<double> args});

/// Numbers per command; the tokenizer reads exactly that many.
const Map<String, int> _arity = {'M': 2, 'H': 1, 'V': 1, 'C': 6, 'Z': 0};

/// The commands of [pillPalMonogramPathData], parsed once.
final List<_Command> _commands = _parse(pillPalMonogramPathData);

List<_Command> _parse(String data) {
  final tokens = RegExp(
    r'[MHVCZ]|-?\d+(?:\.\d+)?',
  ).allMatches(data).map((match) => match.group(0)!).toList();
  final commands = <_Command>[];
  var i = 0;
  while (i < tokens.length) {
    final op = tokens[i++];
    final arity = _arity[op];
    if (arity == null) {
      throw const FormatException('Unsupported monogram path command');
    }
    commands.add((
      op: op,
      args: [for (var k = 0; k < arity; k++) double.parse(tokens[i++])],
    ));
  }
  return commands;
}

/// Draws the monogram in one [color], scaled to fit its box and centred.
///
/// Decorative: it carries no semantics (the wordmark beside it names the
/// app). It fills the (bounded) space it is given and keeps the aspect ratio.
class PillPalMonogram extends StatelessWidget {
  /// Creates the monogram.
  const PillPalMonogram({required this.color, super.key});

  /// Fill colour; callers pass a palette token.
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        painter: PillPalMonogramPainter(color: color),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Paints [pillPalMonogramPathData] with the even-odd rule.
class PillPalMonogramPainter extends CustomPainter {
  /// Creates the painter.
  const PillPalMonogramPainter({required this.color});

  /// Fill colour.
  final Color color;

  /// The monogram path fitted into a box of [size] (the viewBox is scaled
  /// uniformly and centred).
  static Path pathFor(Size size) {
    final scale = size.shortestSide / pillPalMonogramViewBox.width;
    final dx = (size.width - pillPalMonogramViewBox.width * scale) / 2;
    final dy = (size.height - pillPalMonogramViewBox.height * scale) / 2;
    final path = Path()..fillType = PathFillType.evenOdd;
    var x = 0.0;
    var y = 0.0;
    // Maps numbers from the viewBox to the box: even indexes are x.
    List<double> map(List<double> args) => [
          for (var k = 0; k < args.length; k++)
            (args[k] -
                        (k.isEven
                            ? pillPalMonogramViewBox.left
                            : pillPalMonogramViewBox.top)) *
                    scale +
                (k.isEven ? dx : dy),
        ];
    for (final command in _commands) {
      final args = command.args;
      switch (command.op) {
        case 'M':
          (x, y) = (args[0], args[1]);
          final m = map([x, y]);
          path.moveTo(m[0], m[1]);
        case 'H':
          x = args[0];
          final m = map([x, y]);
          path.lineTo(m[0], m[1]);
        case 'V':
          y = args[0];
          final m = map([x, y]);
          path.lineTo(m[0], m[1]);
        case 'C':
          final m = map(args);
          path.cubicTo(m[0], m[1], m[2], m[3], m[4], m[5]);
          (x, y) = (args[4], args[5]);
        default:
          path.close();
      }
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(pathFor(size), Paint()..color = color);
  }

  @override
  bool shouldRepaint(PillPalMonogramPainter oldDelegate) =>
      oldDelegate.color != color;
}
