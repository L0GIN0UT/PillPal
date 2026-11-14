import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import '../common/compact_text.dart';
import '../common/dosage_form.dart';
import '../common/dosage_form_avatar.dart';
import '../common/standard_dosage_form.dart';
import 'dosage_form_picker.dart';

/// The «Форма» field of the medication form: not typed, chosen in
/// [showDosageFormPicker]. [controller] holds the stored value (a standard
/// code, a catalog text, older free text or the «Other» text), so the
/// catalog fills it like any text field; the field shows the localized name
/// of a code and any other text as it is, with the glyph of the form. The
/// form is optional: a filled field has a «remove» button under it
/// (`med-form-clear`). The field has the key `med-form`.
class DosageFormField extends StatefulWidget {
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

  @override
  State<DosageFormField> createState() => _DosageFormFieldState();
}

class _DosageFormFieldState extends State<DosageFormField> {
  /// Whether the picker is open: a second tap does not open another one.
  bool _open = false;

  Future<void> _pick() async {
    if (_open) {
      return;
    }
    _open = true;
    try {
      final picked = await showDosageFormPicker(
        context,
        current: widget.controller.text,
      );
      if (!mounted || picked == null) {
        return;
      }
      widget.controller.text = picked;
      widget.onEdited();
    } finally {
      _open = false;
    }
  }

  void _onTap() => unawaited(_pick());

  void _clear() {
    widget.controller.clear();
    widget.onEdited();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.md),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: widget.controller,
        builder: (context, value, _) => _field(context, value.text),
      ),
    );
  }

  Widget _field(BuildContext context, String stored) {
    final l10n = AppLocalizations.of(context);
    final shown = stored.trim().isEmpty ? '' : dosageFormText(l10n, stored);
    final error = widget.error;
    final value = shown.isEmpty ? l10n.medFormHint : shown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          label: l10n.medFormLabel,
          value: error == null ? value : '$value, $error',
          onTap: _onTap,
          excludeSemantics: true,
          child: InkWell(
            key: const Key('med-form'),
            onTap: _onTap,
            borderRadius: PillPalRadius.control,
            // The fill is an Ink under the decorator: a filled decorator
            // would paint over the ripple of the InkWell.
            child: Ink(
              decoration: ShapeDecoration(
                color: context.palette.surface,
                shape: const RoundedRectangleBorder(
                  borderRadius: PillPalRadius.control,
                ),
              ),
              child: _decorator(context, l10n, stored, shown),
            ),
          ),
        ),
        if (shown.isNotEmpty)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('med-form-clear'),
              onPressed: _clear,
              icon: const Icon(Icons.close),
              label: Text(l10n.medFormClear),
            ),
          ),
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
        filled: false,
        constraints: BoxConstraints(minHeight: context.metrics.touchTarget),
        labelText: l10n.medFormLabel,
        hintText: l10n.medFormHint,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        errorText: widget.error,
        errorMaxLines: 3,
        prefixIcon: avatar,
        suffixIcon: const Icon(Icons.expand_more),
      ),
      child: Text(
        shown,
        key: const Key('med-form-text'),
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    );
  }
}
