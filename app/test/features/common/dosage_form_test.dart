import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/common/dosage_form.dart';

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
}
