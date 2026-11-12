import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/motion.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/choice_button.dart';
import '../common/choice_group.dart';
import '../common/formatters.dart';
import '../common/pillpal_card.dart';
import '../common/popup_menu_item.dart';
import '../common/pillpal_icon_button.dart';
import 'schedule_draft.dart';
import 'schedule_text.dart';

/// Width of the dose amount field of a time slot: room for five digits.
const double _amountFieldWidth = PillPalSizes.doseAmountWidth;

/// Rule kind chips: stadiums with a check on the selected one (B2-Schedule).
class KindSelector extends StatelessWidget {
  /// Creates the selector.
  const KindSelector({required this.value, required this.onChanged, super.key});

  /// Current kind.
  final RuleKind value;

  /// Called with the tapped kind.
  final ValueChanged<RuleKind> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ChoiceGroup<RuleKind>(
      options: {
        for (final kind in RuleKind.values) kind: ruleKindLabel(l10n, kind),
      },
      selected: value,
      onSelected: onChanged,
      keyOf: (kind) => ValueKey('kind-${kind.wireName}'),
    );
  }
}

/// Seven weekday toggles, Monday first.
class WeekdaySelector extends StatelessWidget {
  /// Creates the selector.
  const WeekdaySelector({
    required this.selected,
    required this.onToggle,
    super.key,
  });

  /// Selected ISO weekdays.
  final Set<int> selected;

  /// Called with the tapped weekday.
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    final palette = context.palette;
    return Wrap(
      spacing: PillPalSpacing.chips,
      runSpacing: PillPalSpacing.chips,
      children: [
        for (var day = 1; day <= DateTime.daysPerWeek; day++)
          SizedBox(
            width: context.metrics.touchTarget,
            child: ChoiceButton(
              key: ValueKey('weekday-$day'),
              label: formatWeekdayShort(day, locale),
              selected: selected.contains(day),
              selectedColor: palette.action,
              onTap: () => onToggle(day),
            ),
          ),
      ],
    );
  }
}

/// "Каждые [-] 2 дня [+]".
class IntervalStepper extends StatelessWidget {
  /// Creates the stepper.
  const IntervalStepper(
      {required this.value, required this.onChanged, super.key});

  /// Current N.
  final int value;

  /// Called with the new N.
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return PillPalCard(
      padding: const EdgeInsets.symmetric(
        horizontal: PillPalSpacing.md,
        vertical: PillPalSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.everyNDays(value),
              key: const Key('interval-value'),
              style: textTheme.titleMedium,
            ),
          ),
          PillPalIconButton(
            key: const Key('interval-minus'),
            tooltip: l10n.decrease,
            icon: Icons.remove,
            onPressed: value > RuleLimits.minInterval
                ? () => onChanged(value - 1)
                : null,
          ),
          PillPalIconButton(
            key: const Key('interval-plus'),
            tooltip: l10n.increase,
            icon: Icons.add,
            onPressed: value < RuleLimits.maxInterval
                ? () => onChanged(value + 1)
                : null,
          ),
        ],
      ),
    );
  }
}

/// One time slot: time button, amount, unit menu, remove.
class SlotRow extends StatelessWidget {
  /// Creates the row.
  const SlotRow({
    required this.slot,
    required this.onPickTime,
    required this.onChanged,
    required this.onRemove,
    super.key,
  });

  /// The slot.
  final SlotDraft slot;

  /// Opens the time picker.
  final VoidCallback onPickTime;

  /// Called with the edited slot.
  final ValueChanged<SlotDraft> onChanged;

  /// Removes the slot; null when it is the only one.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final count = num.tryParse(slot.normalizedAmount) ?? 1;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: PillPalSpacing.lg,
        vertical: PillPalSpacing.sm,
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: PillPalSpacing.sm,
        runSpacing: PillPalSpacing.xs,
        children: [
          TextButton(
            key: ValueKey('slot-time-${slot.time}'),
            onPressed: onPickTime,
            style: TextButton.styleFrom(
              foregroundColor: context.palette.ink,
            ),
            child: Text(slot.time, style: textTheme.numeral),
          ),
          SizedBox(
            width: _amountFieldWidth,
            child: TextFormField(
              key: ValueKey('slot-amount-${slot.time}'),
              initialValue: slot.amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              // A decimal keypad has no "next": done closes it.
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: l10n.doseAmountLabel,
                isDense: true,
              ),
              onChanged: (value) => onChanged(slot.copyWith(amount: value)),
            ),
          ),
          PopupMenuButton<DoseUnit>(
            key: ValueKey('slot-unit-${slot.time}'),
            popUpAnimationStyle: PillPalMotion.menu,
            tooltip: l10n.doseUnitLabel,
            initialValue: slot.unit,
            onSelected: (unit) => onChanged(slot.copyWith(unit: unit)),
            itemBuilder: (context) => [
              for (final unit in DoseUnit.values)
                pillPalPopupItem(
                  context,
                  key: ValueKey('unit-${unit.name}'),
                  value: unit,
                  child: Text(doseUnitLabel(l10n, unit, count)),
                ),
            ],
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: math.max(
                  PillPalSizes.unitPickerHeight,
                  context.metrics.touchTarget,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Wraps instead of overflowing at the largest text scale.
                  Flexible(
                    child: Text(
                      doseUnitLabel(l10n, slot.unit, count),
                      style: textTheme.titleSmall,
                    ),
                  ),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
          if (onRemove != null)
            PillPalIconButton(
              key: ValueKey('slot-remove-${slot.time}'),
              tooltip: l10n.removeTime,
              icon: Icons.close,
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}
