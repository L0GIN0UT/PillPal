import '../../../l10n/gen/app_localizations.dart';

/// The standard dosage forms of the form picker. The chosen one is stored as
/// its [code] in the free-text `form` field of a medication (no schema, sync
/// or server change): any other text there (a catalog form such as
/// «ТАБЛЕТКИ, ПОКРЫТЫЕ ПЛЕНОЧНОЙ ОБОЛОЧКОЙ», text typed before the picker,
/// the «Other» text) is shown as it is.
enum StandardDosageForm {
  /// Tablets.
  tablet('tablet'),

  /// Capsules.
  capsule('capsule'),

  /// Solution.
  solution('solution'),

  /// Syrup.
  syrup('syrup'),

  /// Drops.
  drops('drops'),

  /// Spray or inhaler.
  spray('spray'),

  /// Injection.
  injection('injection'),

  /// Ointment, cream or gel.
  ointment('ointment'),

  /// Powder or granules.
  powder('powder'),

  /// Suppositories.
  suppository('suppository'),

  /// Patch.
  patch('patch');

  const StandardDosageForm(this.code);

  /// The stable lowercase code stored in the `form` field: a contract with
  /// stored data, never rename one.
  final String code;

  /// The standard form whose code is exactly [form]; null for any other
  /// text (case matters: «Tablet» typed by hand stays the person's text).
  static StandardDosageForm? ofCode(String? form) {
    for (final standard in values) {
      if (standard.code == form) {
        return standard;
      }
    }
    return null;
  }
}

/// The localized name of [form].
String standardDosageFormLabel(
  AppLocalizations l10n,
  StandardDosageForm form,
) =>
    switch (form) {
      StandardDosageForm.tablet => l10n.dosageFormTablet,
      StandardDosageForm.capsule => l10n.dosageFormCapsule,
      StandardDosageForm.solution => l10n.dosageFormSolution,
      StandardDosageForm.syrup => l10n.dosageFormSyrup,
      StandardDosageForm.drops => l10n.dosageFormDrops,
      StandardDosageForm.spray => l10n.dosageFormSpray,
      StandardDosageForm.injection => l10n.dosageFormInjection,
      StandardDosageForm.ointment => l10n.dosageFormOintment,
      StandardDosageForm.powder => l10n.dosageFormPowder,
      StandardDosageForm.suppository => l10n.dosageFormSuppository,
      StandardDosageForm.patch => l10n.dosageFormPatch,
    };

/// What a screen shows for the stored [form]: the localized name of a
/// standard code, any other text as it is.
String dosageFormText(AppLocalizations l10n, String form) {
  final standard = StandardDosageForm.ofCode(form);
  return standard == null ? form : standardDosageFormLabel(l10n, standard);
}
