import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
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

  /// A group with at most one selected value: a null or unknown [selected]
  /// highlights nothing.
  ChoiceGroup.optional({
    required Map<T, String> options,
    required T? selected,
    required ValueChanged<T> onSelected,
    Key? Function(T value)? keyOf,
    double? itemWidth,
    Color? selectedColor,
    Key? key,
  }) : this.multi(
          options: options,
          selectedValues: {
            if (selected != null && options.containsKey(selected)) selected,
          },
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

  /// Minimum width of each button (weekday chips), never below the touch
  /// target of the mode; null sizes to the label.
  final double? itemWidth;

  /// Background of selected buttons (defaults to ink).
  final Color? selectedColor;

  @override
  Widget build(BuildContext context) {
    assert(
      selectedValues.every(options.containsKey),
      'every selected value must be one of the options',
    );
    return Wrap(
      spacing: PillPalSpacing.chips,
      runSpacing: PillPalSpacing.chips,
      children: [
        for (final entry in options.entries)
          _button(context, entry.key, entry.value),
      ],
    );
  }

  Widget _button(BuildContext context, T value, String label) {
    // ChoiceButton centres its label and so fills the width a Wrap offers;
    // IntrinsicWidth makes a chip as wide as its label.
    final button = IntrinsicWidth(
      child: ChoiceButton(
        key: keyOf?.call(value),
        label: label,
        selected: selectedValues.contains(value),
        selectedColor: selectedColor,
        onTap: () => onSelected(value),
      ),
    );
    final width = itemWidth;
    return width == null
        ? button
        : ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: math.max(width, context.metrics.touchTarget),
            ),
            child: button,
          );
  }
}
