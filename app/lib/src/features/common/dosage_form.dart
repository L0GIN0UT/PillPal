/// The kinds of dosage form the app draws a glyph for (the avatar of
/// `dosage_form_avatar.dart`).
enum DosageForm {
  /// Tablets, dragées, lozenges.
  tablet,

  /// Capsules.
  capsule,

  /// Solutions, syrups, drops, suspensions.
  liquid,

  /// Injections and infusions.
  injection,

  /// Ointments, creams, gels.
  ointment,

  /// Sprays, aerosols, inhalers.
  spray,

  /// Powders and granules.
  powder,

  /// Unknown, missing, or a form with no glyph of its own (suppositories,
  /// patches).
  generic,
}

/// The [DosageForm] of [form], free text from the catalog sources (ESKLP in
/// Russian upper case, RxNorm in English): matched by keywords,
/// case-insensitively. The first matching group wins: a powder for an
/// injection is an injection, a solution for inhalation a spray.
DosageForm dosageFormOf(String? form) {
  final text = form?.toLowerCase();
  if (text == null || text.trim().isEmpty) {
    return DosageForm.generic;
  }
  for (final (keywords, kind) in _groups) {
    if (keywords.any(text.contains)) {
      return kind;
    }
  }
  return DosageForm.generic;
}

/// Keyword groups in priority order, lower case, RU and EN.
const List<(List<String>, DosageForm)> _groups = [
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
    DosageForm.injection,
  ),
  (
    ['спрей', 'аэрозол', 'ингал', 'spray', 'aerosol', 'inhal'],
    DosageForm.spray,
  ),
  // No glyph reads as a suppository: the generic one, not a lookalike.
  (['суппозитор', 'свеч', 'suppositor'], DosageForm.generic),
  (['капсул', 'capsul'], DosageForm.capsule),
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
    DosageForm.tablet,
  ),
  (['порош', 'гранул', 'powder', 'granul'], DosageForm.powder),
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
    DosageForm.ointment,
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
    DosageForm.liquid,
  ),
];
