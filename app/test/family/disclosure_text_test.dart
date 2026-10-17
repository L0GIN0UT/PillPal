import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/family/family_overview.dart';

// What an owner confirms before inviting is versioned (ADR 0005 §3): the
// version is copied to the grant as proof of what was disclosed. Changing a
// disclosed word without a new version would make that proof false.

const List<String> _locales = ['en', 'ru'];

/// The fingerprint of the disclosure texts of version 1. A change of any of
/// them fails the test below until `inviteDisclosureVersion` is raised and
/// this pair is updated together.
const int _fingerprintedVersion = 1;
const String _fingerprint =
    'b18f5fefe5be662033ff5583ffea647330010adbb4fff9b792ff31633ef0bb4a';

bool _isDisclosure(String key) =>
    key.startsWith('disclosure') || key == 'guardianWarning';

String _fingerprintOf(Map<String, Object?> en, Map<String, Object?> ru) {
  final buffer = StringBuffer();
  for (final entry in {'en': en, 'ru': ru}.entries) {
    final keys = entry.value.keys.where(_isDisclosure).toList()..sort();
    for (final key in keys) {
      buffer.write('${entry.key}.$key=${entry.value[key]}\n');
    }
  }
  return sha256.convert(utf8.encode(buffer.toString())).toString();
}

Map<String, Object?> _arb(String locale) =>
    jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
        as Map<String, Object?>;

void main() {
  test('the disclosure texts match the version that was shipped', () {
    final fingerprint = _fingerprintOf(_arb('en'), _arb('ru'));

    expect(
      inviteDisclosureVersion,
      _fingerprintedVersion,
      reason: 'Version and fingerprint move together.',
    );
    expect(
      fingerprint,
      _fingerprint,
      reason: 'A disclosure text changed: raise inviteDisclosureVersion and '
          'update _fingerprintedVersion and _fingerprint ($fingerprint).',
    );
  });

  test('both languages disclose the same set of texts', () {
    final en = _arb('en').keys.where(_isDisclosure).toSet();
    final ru = _arb('ru').keys.where(_isDisclosure).toSet();

    expect(en, isNotEmpty);
    expect(ru, en);
  });

  test('anonymous medications also disclose schedule days and course dates',
      () {
    final en = _arb('en');
    final ru = _arb('ru');

    for (final key in ['disclosureAnonymous', 'privacyExplainAnonymous']) {
      final english = en[key]! as String;
      expect(english, contains('days of the schedule'), reason: key);
      expect(english, contains('course start and end dates'), reason: key);
      final russian = ru[key]! as String;
      expect(russian, contains('днями расписания'), reason: key);
      expect(
        russian,
        contains('датами начала и окончания курса'),
        reason: key,
      );
    }
  });

  test('no disclosure claims anonymous shows only time and status', () {
    for (final locale in _locales) {
      final arb = _arb(locale);
      for (final key in arb.keys.where(_isDisclosure)) {
        expect(arb[key], isNot(contains('only the time')), reason: key);
        expect(arb[key], isNot(contains('только время')), reason: key);
      }
    }
  });
}
