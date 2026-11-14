import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import '../common/compact_text.dart';
import '../common/dosage_form.dart';
import '../common/dosage_form_avatar.dart';
import '../common/gap.dart';
import '../common/sheet_header.dart';
import '../common/sheet_scaffold.dart';
import '../common/standard_dosage_form.dart';
import 'medication_form.dart';

/// Opens the dosage form picker for the stored [current] form. Resolves
/// with the new value of the field (a [StandardDosageForm.code], or the
/// «Other» text, trimmed), or null when the sheet closes without a choice.
Future<String?> showDosageFormPicker(
  BuildContext context, {
  required String current,
}) {
  return showPillPalSheet<String>(
    context,
    (_) => DosageFormPickerSheet(current: current),
  );
}

/// The list of standard forms, each with its glyph, and «Other» with a text
/// field for a rare form. The row matching [current] is marked: its code,
/// or the group of a catalog text («ТАБЛЕТКИ, ПОКРЫТЫЕ ОБОЛОЧКОЙ» marks
/// «Таблетки»). A row has the key `dosage-form-<code>`.
class DosageFormPickerSheet extends StatefulWidget {
  /// Creates the sheet.
  const DosageFormPickerSheet({required this.current, super.key});

  /// What the field holds now.
  final String current;

  @override
  State<DosageFormPickerSheet> createState() => _DosageFormPickerState();
}

class _DosageFormPickerState extends State<DosageFormPickerSheet> {
  late final StandardDosageForm? _marked;
  late final TextEditingController _other;
  late bool _otherOpen;

  /// Whether «Other» was open from the start (the field holds text of no
  /// standard form): the keyboard waits for a tap on the text then.
  late final bool _openAtStart;

  @override
  void initState() {
    super.initState();
    final current = widget.current.trim();
    final isCode = StandardDosageForm.ofCode(current) != null;
    _marked = current.isEmpty ? null : standardDosageFormMatching(current);
    // Free text is offered for editing under «Other»; a code is not text.
    _other = TextEditingController(text: isCode ? '' : current);
    _otherOpen = current.isNotEmpty && _marked == null;
    _openAtStart = _otherOpen;
  }

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  /// What picking [form] stores: its code, or nothing new when it is the
  /// row a catalog or free text marked (that text stays as it is).
  String? _valueOf(StandardDosageForm form) {
    final current = widget.current.trim();
    final keepsText =
        form == _marked && StandardDosageForm.ofCode(current) == null;
    return keepsText ? null : form.code;
  }

  void _submitOther() {
    final text = _other.text.trim();
    if (text.isNotEmpty) {
      Navigator.of(context).pop(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SheetScaffold(
      primaryAction: _otherOpen ? _doneButton(l10n) : null,
      children: [
        SheetHeader(
          title: l10n.dosageFormPickerTitle,
          closeKey: const Key('dosage-form-close'),
        ),
        const Gap.v(PillPalSpacing.sm),
        for (final form in StandardDosageForm.values)
          _FormTile(
            key: ValueKey('dosage-form-${form.code}'),
            glyph: standardDosageGlyph(form),
            label: standardDosageFormLabel(l10n, form),
            selected: !_otherOpen && form == _marked,
            onTap: () => Navigator.of(context).pop(_valueOf(form)),
          ),
        _FormTile(
          key: const Key('dosage-form-other'),
          glyph: DosageForm.generic,
          label: l10n.dosageFormOther,
          selected: _otherOpen,
          onTap: () => setState(() => _otherOpen = true),
        ),
        if (_otherOpen) ...[
          const Gap.v(PillPalSpacing.md),
          TextField(
            key: const Key('dosage-form-other-text'),
            controller: _other,
            autofocus: !_openAtStart,
            inputFormatters: [
              LengthLimitingTextInputFormatter(MedicationLimits.shortText),
            ],
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submitOther(),
            decoration: InputDecoration(
              labelText: l10n.dosageFormOtherLabel,
              hintText: l10n.dosageFormOtherHint,
            ),
          ),
        ],
      ],
    );
  }

  Widget _doneButton(AppLocalizations l10n) => FilledButton(
        key: const Key('dosage-form-other-done'),
        onPressed: _other.text.trim().isEmpty ? null : _submitOther,
        child: Text(l10n.done),
      );
}

/// One row of the picker: the glyph (dropped from the compact text scale
/// on), the name, and a check on the marked row.
class _FormTile extends StatelessWidget {
  const _FormTile({
    required this.glyph,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final DosageForm glyph;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: PillPalSpacing.sm),
      minTileHeight: context.metrics.touchTarget,
      shape: const RoundedRectangleBorder(borderRadius: PillPalRadius.control),
      selected: selected,
      selectedColor: palette.onSelected,
      selectedTileColor: palette.selected,
      leading: isCompactText(context)
          ? null
          : DosageFormAvatar(
              form: glyph,
              background: selected ? palette.surface : null,
            ),
      title: Text(label),
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: onTap,
    );
  }
}
