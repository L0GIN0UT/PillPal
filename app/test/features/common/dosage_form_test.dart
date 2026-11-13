import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/catalog/dosage_form_icon.dart';

// The result avatar by dosage form: ESKLP forms in Russian upper case and
// RxNorm forms in English, matched case-insensitively.

void main() {
  const cases = <String, IconData>{
    'ТАБЛЕТКИ, ПОКРЫТЫЕ ПЛЕНОЧНОЙ ОБОЛОЧКОЙ': Icons.adjust,
    'таблетки': Icons.adjust,
    'ДРАЖЕ': Icons.adjust,
    'Oral Tablet': Icons.adjust,
    'Chewable Tablet': Icons.adjust,
    'КАПСУЛЫ': Icons.toggle_off_outlined,
    'Extended Release Oral Capsule': Icons.toggle_off_outlined,
    'РАСТВОР ДЛЯ ИНЪЕКЦИЙ': Icons.vaccines_outlined,
    'ПОРОШОК ДЛЯ ПРИГОТОВЛЕНИЯ РАСТВОРА ДЛЯ ИНФУЗИЙ': Icons.vaccines_outlined,
    'Injectable Solution': Icons.vaccines_outlined,
    'Prefilled Syringe': Icons.vaccines_outlined,
    'КАПЛИ ГЛАЗНЫЕ': Icons.water_drop_outlined,
    'СИРОП': Icons.water_drop_outlined,
    'СУСПЕНЗИЯ ДЛЯ ПРИЕМА ВНУТРЬ': Icons.water_drop_outlined,
    'Oral Solution': Icons.water_drop_outlined,
    'Ophthalmic Drops': Icons.water_drop_outlined,
    'МАЗЬ': Icons.sanitizer_outlined,
    'КРЕМ ДЛЯ НАРУЖНОГО ПРИМЕНЕНИЯ': Icons.sanitizer_outlined,
    'ГЕЛЬ': Icons.sanitizer_outlined,
    'Topical Cream': Icons.sanitizer_outlined,
    'СПРЕЙ НАЗАЛЬНЫЙ': Icons.air,
    'АЭРОЗОЛЬ ДЛЯ ИНГАЛЯЦИЙ ДОЗИРОВАННЫЙ': Icons.air,
    'РАСТВОР ДЛЯ ИНГАЛЯЦИЙ': Icons.air,
    'Inhalation Powder': Icons.air,
    'Nasal Spray': Icons.air,
    'ПОРОШОК': Icons.grain,
    'ГРАНУЛЫ ДЛЯ ПРИГОТОВЛЕНИЯ СУСПЕНЗИИ': Icons.grain,
    'Oral Powder': Icons.grain,
    'СУППОЗИТОРИИ РЕКТАЛЬНЫЕ': genericDosageFormIcon,
    'Rectal Suppository': genericDosageFormIcon,
  };

  for (final MapEntry(key: form, value: icon) in cases.entries) {
    test('"$form"', () {
      expect(dosageFormIcon(form), icon);
    });
  }

  test('an unknown, empty or missing form gets the generic icon', () {
    expect(dosageFormIcon('Transdermal Patch'), genericDosageFormIcon);
    expect(dosageFormIcon('ПЛАСТЫРЬ'), genericDosageFormIcon);
    expect(dosageFormIcon('  '), genericDosageFormIcon);
    expect(dosageFormIcon(null), genericDosageFormIcon);
    expect(genericDosageFormIcon, Icons.medication_outlined);
  });
}
