import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Static guard of the emulator journeys (docs/redesign-plan.md, "Keys and
// types that must survive"). The journeys in `integration_test/` find widgets
// by key and type; a redesign that drops one breaks a 30-minute job. This test
// reads both source trees as text, so it runs in seconds on every PR.
//
// Only string literals in key positions count: the argument of `Key(`,
// `ValueKey(`, `GlobalKey(` and the value of a named argument that ends in
// `key` (`key:`, `fieldKey:`, `bodyKey:`). Limitation: a key built from a
// variable, such as `Key(prefix + id)`, is invisible to this scan.

/// A string literal in a key position; group 2 is the text, group 3 is `$`
/// when the literal goes on with an interpolation.
final RegExp _keyPosition = RegExp(
  r'''(?:\b(?:Value|Global|Unique|Object)?Key(?:<[^>]*>)?\(|\b\w*[kK]ey\s*:)\s*(?:const\s+)?(['"])([A-Za-z0-9_:/.-]*)(\$|\1)''',
);

/// A prefix the journeys look for with `startsWith`, or keep in a constant.
final RegExp _keyPrefix = RegExp(
  r'''(?:startsWith\(|\bconst prefix = )\s*['"]([a-z][a-z0-9]*(?:-[a-z0-9]+)*-)['"]''',
);

/// The least fixed text before an interpolation that may stand for a key.
const int _minFixedChars = 6;

/// The source without `//` comments (a `//` inside a string is kept: an odd
/// number of quotes before it means it is inside one).
String _withoutComments(String source) => source.split('\n').map((line) {
      for (var i = line.indexOf('//'); i >= 0; i = line.indexOf('//', i + 2)) {
        final before = line.substring(0, i);
        final quotes =
            "'".allMatches(before).length + '"'.allMatches(before).length;
        if (quotes.isEven) {
          return before;
        }
      }
      return line;
    }).join('\n');

/// A key literal of the app: the whole text, or the fixed part before an
/// interpolation.
class _Key {
  const _Key(this.fixed, {required this.templated});
  final String fixed;
  final bool templated;

  /// Whether a templated literal is specific enough to stand for other keys:
  /// `'a$x'` must not vouch for every key that starts with a.
  bool get specific =>
      fixed.length >= _minFixedChars ||
      (fixed.endsWith('-') && fixed.length >= 3);
}

Iterable<File> _dartFiles(String dir, {String? skip}) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .where((f) => skip == null || !f.path.replaceAll(r'\', '/').contains(skip));

String _read(Iterable<File> files) =>
    _withoutComments(files.map((f) => f.readAsStringSync()).join('\n'));

List<_Key> _keysIn(String source) => [
      for (final m in _keyPosition.allMatches(source))
        _Key(m.group(2)!, templated: m.group(3) == r'$'),
    ];

/// A key the journeys use: exact, or a prefix of keys built at run time.
class _JourneyKey {
  const _JourneyKey(this.text, {required this.isPrefix});
  final String text;
  final bool isPrefix;

  @override
  String toString() => isPrefix ? '$text<...>' : text;
}

List<_JourneyKey> _journeyKeys(String source) => [
      for (final k in _keysIn(source))
        if (!k.templated)
          _JourneyKey(k.fixed, isPrefix: false)
        else if (k.fixed.isNotEmpty)
          _JourneyKey(k.fixed, isPrefix: true),
      for (final m in _keyPrefix.allMatches(source))
        _JourneyKey(m.group(1)!, isPrefix: true),
    ];

bool _provided(_JourneyKey key, List<_Key> lib) {
  for (final c in lib) {
    if (key.isPrefix) {
      if (c.fixed.startsWith(key.text) ||
          (c.templated && c.specific && key.text.startsWith(c.fixed))) {
        return true;
      }
    } else if (!c.templated && c.fixed == key.text) {
      return true;
    } else if (c.templated && c.specific && key.text.startsWith(c.fixed)) {
      return true;
    }
  }
  return false;
}

bool _declaresClass(String source, String name) =>
    RegExp('^class $name\\b', multiLine: true).hasMatch(source);

void main() {
  final lib = _read(_dartFiles('lib', skip: 'lib/l10n/gen/'));
  final journeys = _read(_dartFiles('integration_test'));

  test('the journeys use keys at all (the scan itself works)', () {
    final keys = _journeyKeys(journeys);
    expect(keys.length, greaterThan(20));
    expect(
      keys.map((k) => k.text),
      containsAll(['welcome-register', 'today-add', 'dose-take-']),
    );
  });

  test('every key of the journeys is still built in lib/', () {
    final provided = _keysIn(lib);
    final missing = [
      for (final key in _journeyKeys(journeys))
        if (!_provided(key, provided)) key,
    ];
    expect(
      missing,
      isEmpty,
      reason: 'integration_test/ looks for keys that lib/ no longer has: '
          '$missing. Keep the key (docs/redesign-plan.md) or change the '
          'journey on purpose.',
    );
  });

  group('the scan', () {
    List<_Key> keys(String source) => _keysIn(_withoutComments(source));
    const gone = _JourneyKey('gone', isPrefix: false);

    test('reports a key that lib/ lacks and accepts one it has', () {
      final provided = keys("const Key('there');");
      expect(_provided(gone, provided), isFalse);
      expect(
        _provided(const _JourneyKey('there', isPrefix: false), provided),
        isTrue,
      );
    });

    test('a templated literal stands for keys with its prefix', () {
      final provided = keys(r"ValueKey('slot-time-${slot.time}')");
      expect(
        _provided(
          const _JourneyKey('slot-time-08:00', isPrefix: false),
          provided,
        ),
        isTrue,
      );
      expect(
        _provided(const _JourneyKey('slot-', isPrefix: true), provided),
        isTrue,
      );
    });

    test('a short template does not vouch for unrelated keys', () {
      final provided = keys(r"Key('a$x')");
      expect(
        _provided(const _JourneyKey('abc', isPrefix: false), provided),
        isFalse,
      );
    });

    test('a log string or a comment is not a key', () {
      final provided = keys(
        "log('welcome-register shown'); // Key('today-add')\n"
        "final text = 'dose-take-';",
      );
      expect(provided, isEmpty);
    });

    test('a name passed to a *Key parameter is a key', () {
      final provided = keys("MedField(fieldKey: 'med-name')");
      expect(
        _provided(const _JourneyKey('med-name', isPrefix: false), provided),
        isTrue,
      );
    });
  });

  test('the types the journeys rely on exist in lib/', () {
    expect(_declaresClass(lib, 'DoseTile'), isTrue);
    expect(_declaresClass(lib, 'PillPalApp'), isTrue);
    expect(lib, contains('NavigationBar('));
    expect(lib, contains('showTimePicker('));
    expect(
      _declaresClass('// class DoseTile\nclass Other {}', 'DoseTile'),
      isFalse,
    );
  });

  test('the journeys still use the types this test protects', () {
    expect(journeys, contains('DoseTile'));
    expect(journeys, contains('PillPalApp'));
    expect(journeys, contains('NavigationBar'));
    expect(journeys, contains('TimePickerDialog'));
  });
}
