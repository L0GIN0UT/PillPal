import 'package:material_ui/material_ui.dart';

/// The icon of a catalog dosage form: [form] is free text from the
/// sources (ESKLP in Russian upper case, RxNorm in English), so it is
/// matched by keywords, case-insensitively. Unknown or missing forms get
/// the generic medication icon. The first matching group wins: a powder
/// for an injection is an injection, a solution for inhalation an inhaler.
IconData dosageFormIcon(String? form) {
  final text = form?.toLowerCase();
  if (text == null || text.trim().isEmpty) {
    return genericDosageFormIcon;
  }
  for (final (keywords, icon) in _groups) {
    if (keywords.any(text.contains)) {
      return icon;
    }
  }
  return genericDosageFormIcon;
}

/// The icon of an unknown form.
const IconData genericDosageFormIcon = Icons.medication_outlined;

/// Keyword groups in priority order, lower case, RU and EN.
const List<(List<String>, IconData)> _groups = [
  (
    [
      'инъекц',
      'инфуз',
      'шприц',
      'inject',
      'infusion',
      'syringe',
      'cartridge',
    ],
    Icons.vaccines_outlined,
  ),
  (
    ['спрей', 'аэрозол', 'ингал', 'spray', 'aerosol', 'inhal'],
    Icons.air,
  ),
  // No Material icon reads as a suppository; the generic one, not a lookalike.
  (['суппозитор', 'свеч', 'suppositor'], genericDosageFormIcon),
  (['капсул', 'capsul'], Icons.toggle_off_outlined),
  (
    [
      'таблет',
      'драже',
      'пастил',
      'леденц',
      'tablet',
      'pill',
      'caplet',
      'lozenge',
      'troche',
    ],
    Icons.adjust,
  ),
  (['порош', 'гранул', 'powder', 'granul'], Icons.grain),
  (
    [
      'мазь',
      'крем',
      'гель',
      'линимент',
      'паста',
      'ointment',
      'cream',
      'gel',
      'lotion',
      'paste',
    ],
    Icons.sanitizer_outlined,
  ),
  (
    [
      'раствор',
      'сироп',
      'капл',
      'суспенз',
      'эмульс',
      'эликсир',
      'настойк',
      'микстур',
      'solution',
      'syrup',
      'drop',
      'suspension',
      'emulsion',
      'elixir',
      'tincture',
      'liquid',
    ],
    Icons.water_drop_outlined,
  ),
];
