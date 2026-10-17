import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/gen/app_localizations.dart';
import 'medication_form.dart';

/// The localized text of a form error [code] (from [MedicationFormErrors]);
/// null without an error.
String? medicationErrorText(AppLocalizations l10n, String? code) {
  switch (code) {
    case null:
      return null;
    case MedicationFormErrors.required:
      return l10n.fieldRequired;
    case MedicationFormErrors.invalidZone:
      return l10n.invalidZone;
    case MedicationFormErrors.invalid:
      return l10n.invalidValue;
    default:
      return l10n.invalidNumber;
  }
}

/// A length-limited text field of the medication form.
class MedicationTextField extends StatelessWidget {
  /// Creates the field.
  const MedicationTextField({
    required this.controller,
    required this.fieldKey,
    required this.label,
    required this.max,
    required this.onEdited,
    this.hint,
    this.error,
    super.key,
  });

  /// Text controller.
  final TextEditingController controller;

  /// Widget key of the inner field (tests and e2e find it by it).
  final String fieldKey;

  /// Label.
  final String label;

  /// Maximum length.
  final int max;

  /// Called when the text changes.
  final VoidCallback onEdited;

  /// Hint text.
  final String? hint;

  /// Error text.
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: Key(fieldKey),
        controller: controller,
        inputFormatters: [LengthLimitingTextInputFormatter(max)],
        onChanged: (_) => onEdited(),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: error,
          errorMaxLines: 3,
        ),
      ),
    );
  }
}

/// Name, strength, form and notes.
class MedicationTextFields extends StatelessWidget {
  /// Creates the fields.
  const MedicationTextFields({
    required this.name,
    required this.strength,
    required this.form,
    required this.notes,
    required this.errorOf,
    required this.onEdited,
    super.key,
  });

  /// Name field.
  final TextEditingController name;

  /// Strength field.
  final TextEditingController strength;

  /// Form field.
  final TextEditingController form;

  /// Notes field.
  final TextEditingController notes;

  /// The error text of a field.
  final String? Function(MedicationField field) errorOf;

  /// Called when any text changes.
  final VoidCallback onEdited;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        MedicationTextField(
          controller: name,
          fieldKey: 'med-name',
          label: l10n.medNameLabel,
          max: MedicationLimits.name,
          onEdited: onEdited,
          error: errorOf(MedicationField.medicationName),
        ),
        MedicationTextField(
          controller: strength,
          fieldKey: 'med-strength',
          label: l10n.medStrengthLabel,
          max: MedicationLimits.shortText,
          hint: l10n.medStrengthHint,
          onEdited: onEdited,
          error: errorOf(MedicationField.strength),
        ),
        MedicationTextField(
          controller: form,
          fieldKey: 'med-form',
          label: l10n.medFormLabel,
          max: MedicationLimits.shortText,
          hint: l10n.medFormHint,
          onEdited: onEdited,
          error: errorOf(MedicationField.form),
        ),
        MedicationTextField(
          controller: notes,
          fieldKey: 'med-notes',
          label: l10n.medNotesLabel,
          max: MedicationLimits.notes,
          hint: l10n.medNotesHint,
          onEdited: onEdited,
          error: errorOf(MedicationField.notes),
        ),
      ],
    );
  }
}

/// The fixed-zone switch and its zone field.
class MedicationZoneFields extends StatelessWidget {
  /// Creates the section.
  const MedicationZoneFields({
    required this.fixed,
    required this.zone,
    required this.onFixed,
    required this.onEdited,
    this.error,
    super.key,
  });

  /// Whether the medication has a fixed zone.
  final bool fixed;

  /// Zone field.
  final TextEditingController zone;

  /// Switch toggled.
  final ValueChanged<bool> onFixed;

  /// Called when the zone text changes.
  final VoidCallback onEdited;

  /// Error text of the zone.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const Key('med-zone-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.fixedZoneTitle),
          subtitle: Text(l10n.fixedZoneHint),
          value: fixed,
          onChanged: onFixed,
        ),
        if (fixed)
          MedicationTextField(
            controller: zone,
            fieldKey: 'med-zone',
            label: l10n.zoneLabel,
            max: MedicationLimits.shortText,
            hint: 'Europe/Moscow',
            onEdited: onEdited,
            error: error,
          ),
      ],
    );
  }
}
