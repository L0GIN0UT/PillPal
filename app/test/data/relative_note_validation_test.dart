import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/repositories/local_writer.dart';
import 'package:pillpal/src/data/repositories/validation.dart';

// The private relative note (docs/adr/0020 §4): 1-20 visible characters on
// one line, trimmed, counted in code points like the server's len().

void main() {
  test('a short note in any script is accepted and trimmed', () {
    expect(isRelativeNote('Сын'), isTrue);
    expect(relativeNote('  Мама  ', 'note'), 'Мама');
    // Digits and symbols only are fine: no letter rule for a label.
    expect(isRelativeNote('№1'), isTrue);
  });

  test('empty and whitespace-only notes are refused', () {
    expect(isRelativeNote(''), isFalse);
    expect(isRelativeNote('   '), isFalse);
    expect(
      () => relativeNote(' ', 'note'),
      throwsA(
        isA<DataException>()
            .having((e) => e.code, 'code', DataException.validationError)
            .having((e) => e.field, 'field', 'note'),
      ),
    );
  });

  test('the limit is 20 code points, an emoji counts once', () {
    expect(isRelativeNote('а' * 20), isTrue);
    expect(isRelativeNote('а' * 21), isFalse);
    // 20 astral characters: 40 UTF-16 units, 20 code points.
    expect(isRelativeNote('\u{1F600}' * 20), isTrue);
  });

  test('line breaks, tabs, bidi and zero-width characters are refused', () {
    for (final hidden in [
      // Inside the text: trimming must not be what removes them.
      'Сын\nМама',
      'Сын\tМама',
      'Сы\u200bн',
      'Сы\u202eн',
      'Сын\u2028Мама',
      'Сы\u061cн',
      'Сы\ufeffн',
      'Сы\u0085н',
    ]) {
      expect(isRelativeNote(hidden), isFalse, reason: hidden.runes.toString());
    }
  });
}
