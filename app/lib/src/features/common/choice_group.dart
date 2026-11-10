import 'package:flutter/material.dart';

import '../../theme/spacing.dart';
import 'choice_button.dart';

/// A wrapping group of [ChoiceButton]s (chips) in one look: spacing
/// `PillPalSpacing.chips`, targets of the mode. Wrapping chips, not a
/// segmented control, so labels fit senior-mode text.
///
/// [options] keeps its order (a map literal does). Give [key] to the group
/// itself; [keyOf] gives each option's button its key (`level-*`, `slot-*`).
class ChoiceGroup<T> extends StatelessWidget {
  /// A group with one selected value.
  ChoiceGroup({
    required Map<T, String> options,
    required T selected,
    required ValueChanged<T> onSelected,
    Key? Function(T value)? keyOf,
    double? itemWidth,
    Color? selectedColor,
    Key? key,
  }) : this.multi(
          options: options,
          selectedValues: {selected},
          onSelected: onSelected,
          keyOf: keyOf,
          itemWidth: itemWidth,
          selectedColor: selectedColor,
          key: key,
        );

  /// A group where several values are selected; [onSelected] gets the tapped
  /// value so the caller toggles it.
  const ChoiceGroup.multi({
    required this.options,
    required this.selectedValues,
    required this.onSelected,
    this.keyOf,
    this.itemWidth,
    this.selectedColor,
    super.key,
  });

  /// Values and their labels, in display order.
  final Map<T, String> options;

  /// The values shown as selected.
  final Set<T> selectedValues;

  /// Called with the tapped value.
  final ValueChanged<T> onSelected;

  /// Key of the button of a value.
  final Key? Function(T value)? keyOf;

  /// A fixed width of each button (weekday chips); null sizes to the label.
  final double? itemWidth;

  /// Background of selected buttons (defaults to ink).
  final Color? selectedColor;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: PillPalSpacing.chips,
      runSpacing: PillPalSpacing.chips,
      children: [
        for (final entry in options.entries) _button(entry.key, entry.value),
      ],
    );
  }

  Widget _button(T value, String label) {
    final button = ChoiceButton(
      key: keyOf?.call(value),
      label: label,
      selected: selectedValues.contains(value),
      selectedColor: selectedColor,
      onTap: () => onSelected(value),
    );
    final width = itemWidth;
    return width == null ? button : SizedBox(width: width, child: button);
  }
}
