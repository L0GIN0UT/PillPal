import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import '../common/compact_text.dart';
import '../common/dosage_form.dart';
import '../common/dosage_form_avatar.dart';
import '../common/gap.dart';
import '../common/pillpal_icon_button.dart';
import '../common/standard_dosage_form.dart';
import 'dosage_form_picker.dart';

/// The «Форма» field of the medication form: not typed, chosen in
/// [showDosageFormPicker]. [controller] holds the stored value (a standard
/// code, a catalog text, older free text or the «Other» text), so the
/// catalog fills it like any text field; the field shows the localized name
/// of a code and any other text as it is, with the glyph of the form. The
/// form is optional: a filled field has a clear button (`med-form-clear`).
/// The field has the key `med-form`.
class DosageFormField extends StatelessWidget {
  /// Creates the field.
  const DosageFormField({
    required this.controller,
    required this.onEdited,
    this.error,
    super.key,
  });

  /// The stored value.
  final TextEditingController controller;

  /// Called when the value changes.
  final VoidCallback onEdited;

  /// Error text.
  final String? error;

  Future<void> _pick(BuildContext context) async {
    final picked = await showDosageFormPicker(
      context,
      current: controller.text,
    );
    if (picked != null) {
      controller.text = picked;
      onEdited();
    }
  }

  void _clear() {
    controller.clear();
    onEdited();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.md),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => _field(context, value.text),
      ),
    );
  }

  Widget _field(BuildContext context, String stored) {
    final l10n = AppLocalizations.of(context);
    final shown = stored.trim().isEmpty ? '' : dosageFormText(l10n, stored);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Semantics(
            container: true,
            button: true,
            label: l10n.medFormLabel,
            value: shown.isEmpty ? l10n.medFormHint : shown,
            hint: error,
            // The tap stays on this node; the drawn label, text and error
            // do not repeat what it already says.
            child: InkWell(
              key: const Key('med-form'),
              // The corner of the field border, so the ripple stays inside.
              borderRadius: PillPalRadius.control,
              onTap: () => unawaited(_pick(context)),
              child: ExcludeSemantics(
                child: _decorator(context, l10n, stored, shown),
              ),
            ),
          ),
        ),
        if (shown.isNotEmpty) ...[
          const Gap.h(PillPalSpacing.xs),
          PillPalIconButton(
            key: const Key('med-form-clear'),
            icon: Icons.close,
            tooltip: l10n.medFormClear,
            onPressed: _clear,
          ),
        ],
      ],
    );
  }

  Widget _decorator(
    BuildContext context,
    AppLocalizations l10n,
    String stored,
    String shown,
  ) {
    final avatar = shown.isEmpty || isCompactText(context)
        ? null
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: PillPalSpacing.sm),
            child: DosageFormAvatar(form: dosageFormOf(stored)),
          );
    return InputDecorator(
      isEmpty: shown.isEmpty,
      decoration: InputDecoration(
        labelText: l10n.medFormLabel,
        hintText: l10n.medFormHint,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        errorText: error,
        errorMaxLines: 3,
        prefixIcon: avatar,
        suffixIcon: const Icon(Icons.expand_more),
      ),
      child: Text(shown, key: const Key('med-form-text')),
    );
  }
}
