import 'standard_dosage_form.dart';

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

/// The [DosageForm] of [form]: a [StandardDosageForm] code by its glyph,
/// or free text from the catalog sources (ESKLP in Russian upper case,
/// RxNorm in English) matched by keywords, case-insensitively. The first
/// matching group wins: a powder for an injection is an injection, a
/// solution for inhalation a spray.
DosageForm dosageFormOf(String? form) {
  if (StandardDosageForm.ofCode(form) case final standard?) {
    return standardDosageGlyph(standard);
  }
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

/// The glyph of a standard form: suppositories and patches have none of
/// their own, solutions, syrups and drops share the liquid one.
DosageForm standardDosageGlyph(StandardDosageForm form) => switch (form) {
      StandardDosageForm.tablet => DosageForm.tablet,
      StandardDosageForm.capsule => DosageForm.capsule,
      StandardDosageForm.solution ||
      StandardDosageForm.syrup ||
      StandardDosageForm.drops =>
        DosageForm.liquid,
      StandardDosageForm.spray => DosageForm.spray,
      StandardDosageForm.injection => DosageForm.injection,
      StandardDosageForm.ointment => DosageForm.ointment,
      StandardDosageForm.powder => DosageForm.powder,
      StandardDosageForm.suppository ||
      StandardDosageForm.patch =>
        DosageForm.generic,
    };

/// The standard form the picker marks for the stored [form]: the code
/// itself, or the group of free text (a catalog form) by [dosageFormOf],
/// narrowed within the liquid and generic groups by keywords. Null when
/// nothing matches: the text is an «Other» form.
StandardDosageForm? standardDosageFormMatching(String form) {
  if (StandardDosageForm.ofCode(form) case final standard?) {
    return standard;
  }
  final glyph = dosageFormOf(form);
  final text = form.toLowerCase();
  bool mentions(List<String> keywords) => keywords.any(text.contains);
  return switch (glyph) {
    DosageForm.liquid when mentions(['сироп', 'syrup']) =>
      StandardDosageForm.syrup,
    DosageForm.liquid when mentions(['капл', 'drop']) =>
      StandardDosageForm.drops,
    DosageForm.liquid => StandardDosageForm.solution,
    DosageForm.generic when mentions(['суппозитор', 'свеч', 'suppositor']) =>
      StandardDosageForm.suppository,
    DosageForm.generic when mentions(['пластыр', 'patch']) =>
      StandardDosageForm.patch,
    DosageForm.generic => null,
    DosageForm.tablet => StandardDosageForm.tablet,
    DosageForm.capsule => StandardDosageForm.capsule,
    DosageForm.spray => StandardDosageForm.spray,
    DosageForm.injection => StandardDosageForm.injection,
    DosageForm.ointment => StandardDosageForm.ointment,
    DosageForm.powder => StandardDosageForm.powder,
  };
}
