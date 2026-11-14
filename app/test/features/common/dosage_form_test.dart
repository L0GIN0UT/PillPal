import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/common/dosage_form.dart';
import 'package:pillpal/src/features/common/standard_dosage_form.dart';
import 'package:pillpal/l10n/gen/app_localizations_en.dart';

// The dosage form of a catalog row: ESKLP forms in Russian upper case and
// RxNorm forms in English, matched case-insensitively.

void main() {
  const cases = <String, DosageForm>{
    'ТАБЛЕТКИ, ПОКРЫТЫЕ ПЛЕНОЧНОЙ ОБОЛОЧКОЙ': DosageForm.tablet,
    'таблетки': DosageForm.tablet,
    'ДРАЖЕ': DosageForm.tablet,
    'Oral Tablet': DosageForm.tablet,
    'Chewable Tablet': DosageForm.tablet,
    'КАПСУЛЫ': DosageForm.capsule,
    'Extended Release Oral Capsule': DosageForm.capsule,
    'РАСТВОР ДЛЯ ИНЪЕКЦИЙ': DosageForm.injection,
    'ПОРОШОК ДЛЯ ПРИГОТОВЛЕНИЯ РАСТВОРА ДЛЯ ИНФУЗИЙ': DosageForm.injection,
    'Injectable Solution': DosageForm.injection,
    'Prefilled Syringe': DosageForm.injection,
    'КАПЛИ ГЛАЗНЫЕ': DosageForm.liquid,
    'СИРОП': DosageForm.liquid,
    'СУСПЕНЗИЯ ДЛЯ ПРИЕМА ВНУТРЬ': DosageForm.liquid,
    'Oral Solution': DosageForm.liquid,
    'Ophthalmic Drops': DosageForm.liquid,
    'МАЗЬ': DosageForm.ointment,
    'КРЕМ ДЛЯ НАРУЖНОГО ПРИМЕНЕНИЯ': DosageForm.ointment,
    'ГЕЛЬ': DosageForm.ointment,
    'Topical Cream': DosageForm.ointment,
    'СПРЕЙ НАЗАЛЬНЫЙ': DosageForm.spray,
    'АЭРОЗОЛЬ ДЛЯ ИНГАЛЯЦИЙ ДОЗИРОВАННЫЙ': DosageForm.spray,
    'РАСТВОР ДЛЯ ИНГАЛЯЦИЙ': DosageForm.spray,
    'Inhalation Powder': DosageForm.spray,
    'Nasal Spray': DosageForm.spray,
    'ПОРОШОК': DosageForm.powder,
    'ГРАНУЛЫ ДЛЯ ПРИГОТОВЛЕНИЯ СУСПЕНЗИИ': DosageForm.powder,
    'Oral Powder': DosageForm.powder,
    // No glyph reads as a suppository: the generic one.
    'СУППОЗИТОРИИ РЕКТАЛЬНЫЕ': DosageForm.generic,
    'Rectal Suppository': DosageForm.generic,
  };

  for (final MapEntry(key: form, value: kind) in cases.entries) {
    test('"$form"', () {
      expect(dosageFormOf(form), kind);
    });
  }

  test('an unknown, empty or missing form is generic', () {
    expect(dosageFormOf('Transdermal Patch'), DosageForm.generic);
    expect(dosageFormOf('ПЛАСТЫРЬ'), DosageForm.generic);
    expect(dosageFormOf('  '), DosageForm.generic);
    expect(dosageFormOf(null), DosageForm.generic);
  });

  group('standard codes of the picker', () {
    const glyphs = <String, DosageForm>{
      'tablet': DosageForm.tablet,
      'capsule': DosageForm.capsule,
      'solution': DosageForm.liquid,
      'syrup': DosageForm.liquid,
      'drops': DosageForm.liquid,
      'spray': DosageForm.spray,
      'injection': DosageForm.injection,
      'ointment': DosageForm.ointment,
      'powder': DosageForm.powder,
      'suppository': DosageForm.generic,
      'patch': DosageForm.generic,
    };

    test('every standard form has a glyph case', () {
      expect(
        StandardDosageForm.values.map((form) => form.code),
        unorderedEquals(glyphs.keys),
      );
    });

    for (final MapEntry(key: code, value: kind) in glyphs.entries) {
      test('code "$code"', () {
        expect(dosageFormOf(code), kind);
        expect(StandardDosageForm.ofCode(code)?.code, code);
      });
    }

    test('only the exact code is a code', () {
      expect(StandardDosageForm.ofCode('Tablet'), isNull);
      expect(StandardDosageForm.ofCode(' tablet'), isNull);
      expect(StandardDosageForm.ofCode(''), isNull);
      expect(StandardDosageForm.ofCode(null), isNull);
    });

    test('a code shows its label, any other text stays as it is', () {
      final l10n = AppLocalizationsEn();
      expect(dosageFormText(l10n, 'drops'), 'Drops');
      expect(dosageFormText(l10n, 'suppository'), 'Suppositories');
      expect(
        dosageFormText(l10n, 'ТАБЛЕТКИ, ПОКРЫТЫЕ ПЛЕНОЧНОЙ ОБОЛОЧКОЙ'),
        'ТАБЛЕТКИ, ПОКРЫТЫЕ ПЛЕНОЧНОЙ ОБОЛОЧКОЙ',
      );
      expect(dosageFormText(l10n, 'Lozenges'), 'Lozenges');
    });
  });

  group('the picker row a stored form marks', () {
    const cases = <String, StandardDosageForm?>{
      'capsule': StandardDosageForm.capsule,
      'ТАБЛЕТКИ, ПОКРЫТЫЕ ПЛЕНОЧНОЙ ОБОЛОЧКОЙ': StandardDosageForm.tablet,
      'СИРОП': StandardDosageForm.syrup,
      'КАПЛИ ГЛАЗНЫЕ': StandardDosageForm.drops,
      'Oral Solution': StandardDosageForm.solution,
      'РАСТВОР ДЛЯ ИНЪЕКЦИЙ': StandardDosageForm.injection,
      'СУППОЗИТОРИИ РЕКТАЛЬНЫЕ': StandardDosageForm.suppository,
      'Transdermal Patch': StandardDosageForm.patch,
      'ГРАНУЛЫ': StandardDosageForm.powder,
      'Implant': null,
    };
    for (final MapEntry(key: form, value: standard) in cases.entries) {
      test('"$form"', () {
        expect(standardDosageFormMatching(form), standard);
      });
    }
  });
}
