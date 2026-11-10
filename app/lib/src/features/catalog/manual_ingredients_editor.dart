import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/catalog/manual_ingredient.dart';
import '../../data/repositories/validation.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import 'catalog_search_sheet.dart';

/// The private manual composition of a medication: up to ten lines, each a
/// name and a strength as typed. A line picked from the catalog keeps its
/// substance id, which is what the "both contain" hint compares (free text
/// never is). The list stays with the medication; the catalog never gets it.
class ManualIngredientsEditor extends StatefulWidget {
  /// Creates the editor with the [initial] lines; [onChanged] gets the
  /// non-empty lines after every edit.
  const ManualIngredientsEditor({
    required this.initial,
    required this.onChanged,
    super.key,
  });

  /// The stored lines.
  final List<ManualIngredient> initial;

  /// Called with the lines (those with a name) after every change.
  final ValueChanged<List<ManualIngredient>> onChanged;

  @override
  State<ManualIngredientsEditor> createState() =>
      _ManualIngredientsEditorState();
}

class _Line {
  _Line(ManualIngredient source)
      : name = TextEditingController(text: source.name),
        strength = TextEditingController(text: source.strengthText),
        substanceId = source.substanceId,
        pickedName = source.substanceId == null ? null : source.name;

  final TextEditingController name;
  final TextEditingController strength;

  /// The catalog substance this line was picked as; dropped when the name
  /// is edited, so a changed text never keeps a stale id.
  String? substanceId;
  String? pickedName;

  void dispose() {
    name.dispose();
    strength.dispose();
  }
}

class _ManualIngredientsEditorState extends State<ManualIngredientsEditor> {
  late final List<_Line> _lines = [
    for (final line in widget.initial) _Line(line),
  ];

  @override
  void dispose() {
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  void _emit() {
    final lines = <ManualIngredient>[];
    for (final line in _lines) {
      final name = line.name.text.trim();
      if (name.isEmpty) {
        continue;
      }
      final strength = line.strength.text.trim();
      lines.add(
        ManualIngredient(
          name: name,
          strengthText: strength.isEmpty ? null : strength,
          substanceId: line.substanceId,
        ),
      );
    }
    widget.onChanged(lines);
  }

  void _nameEdited(_Line line) {
    if (line.substanceId != null && line.name.text != line.pickedName) {
      line.substanceId = null;
      line.pickedName = null;
    }
    _emit();
  }

  void _remove(_Line line) {
    setState(() => _lines.remove(line));
    // Its fields are still in the tree until the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => line.dispose());
    _emit();
  }

  void _add() {
    setState(() => _lines.add(_Line(const ManualIngredient(name: ''))));
  }

  Future<void> _pick() async {
    final result = await showCatalogSearchSheet(
      context,
      kind: CatalogSearchKind.substance,
    );
    if (result == null || !mounted) {
      return;
    }
    final runes = result.name.runes.take(FieldLimits.ingredientName);
    setState(() {
      _lines.add(
        _Line(
          ManualIngredient(
            name: String.fromCharCodes(runes),
            substanceId: result.id,
          ),
        ),
      );
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final full = _lines.length >= FieldLimits.manualIngredients;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.manualIngTitle, style: textTheme.titleMedium),
        const Gap.v(PillPalSpacing.xs),
        Text(l10n.manualIngHint, style: textTheme.bodySmall),
        const Gap.v(PillPalSpacing.md),
        for (var i = 0; i < _lines.length; i++) _lineFields(l10n, i),
        if (full)
          Text(l10n.manualIngMax, key: const Key('manual-ing-max'))
        else
          Wrap(
            spacing: PillPalSpacing.sm,
            runSpacing: PillPalSpacing.sm,
            children: [
              OutlinedButton.icon(
                key: const Key('manual-ing-add'),
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: Text(l10n.manualIngAdd),
              ),
              OutlinedButton.icon(
                key: const Key('manual-ing-pick'),
                onPressed: _pick,
                icon: const Icon(Icons.search),
                label: Text(l10n.manualIngPick),
              ),
            ],
          ),
      ],
    );
  }

  Widget _lineFields(AppLocalizations l10n, int index) {
    final line = _lines[index];
    return Padding(
      key: ObjectKey(line),
      padding: const EdgeInsets.only(bottom: PillPalSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: Key('manual-ing-name-$index'),
            controller: line.name,
            inputFormatters: [
              LengthLimitingTextInputFormatter(FieldLimits.ingredientName),
            ],
            onChanged: (_) => _nameEdited(line),
            decoration: InputDecoration(labelText: l10n.manualIngNameLabel),
          ),
          const Gap.v(PillPalSpacing.sm),
          TextField(
            key: Key('manual-ing-strength-$index'),
            controller: line.strength,
            inputFormatters: [
              LengthLimitingTextInputFormatter(FieldLimits.ingredientStrength),
            ],
            onChanged: (_) => _emit(),
            decoration: InputDecoration(
              labelText: l10n.manualIngStrengthLabel,
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              key: Key('manual-ing-remove-$index'),
              onPressed: () => _remove(line),
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.manualIngRemove),
            ),
          ),
        ],
      ),
    );
  }
}
