import 'package:flutter/material.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/palette.dart';
import '../common/choice_button.dart';
import '../common/formatters.dart';
import 'schedule_draft.dart';
import 'schedule_text.dart';

/// Rule kind chips (mockup "Schedule").
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
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final kind in RuleKind.values)
          ChoiceButton(
            key: ValueKey('kind-${kind.wireName}'),
            label: ruleKindLabel(l10n, kind),
            selected: kind == value,
            onTap: () => onChanged(kind),
          ),
      ],
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
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var day = 1; day <= DateTime.daysPerWeek; day++)
          SizedBox(
            width: 44,
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.everyNDays(value),
                key: const Key('interval-value'),
                style: textTheme.titleMedium,
              ),
            ),
            IconButton(
              key: const Key('interval-minus'),
              tooltip: l10n.decrease,
              icon: const Icon(Icons.remove),
              onPressed: value > RuleLimits.minInterval
                  ? () => onChanged(value - 1)
                  : null,
            ),
            IconButton(
              key: const Key('interval-plus'),
              tooltip: l10n.increase,
              icon: const Icon(Icons.add),
              onPressed: value < RuleLimits.maxInterval
                  ? () => onChanged(value + 1)
                  : null,
            ),
          ],
        ),
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
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          TextButton(
            key: ValueKey('slot-time-${slot.time}'),
            onPressed: onPickTime,
            child: Text(slot.time, style: textTheme.titleLarge),
          ),
          SizedBox(
            width: 80,
            child: TextFormField(
              key: ValueKey('slot-amount-${slot.time}'),
              initialValue: slot.amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: l10n.doseAmountLabel,
                isDense: true,
              ),
              onChanged: (value) => onChanged(slot.copyWith(amount: value)),
            ),
          ),
          PopupMenuButton<DoseUnit>(
            key: ValueKey('slot-unit-${slot.time}'),
            tooltip: l10n.doseUnitLabel,
            initialValue: slot.unit,
            onSelected: (unit) => onChanged(slot.copyWith(unit: unit)),
            itemBuilder: (context) => [
              for (final unit in DoseUnit.values)
                PopupMenuItem(
                  key: ValueKey('unit-${unit.name}'),
                  value: unit,
                  child: Text(doseUnitLabel(l10n, unit, count)),
                ),
            ],
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    doseUnitLabel(l10n, slot.unit, count),
                    style: textTheme.titleSmall,
                  ),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
          if (onRemove != null)
            IconButton(
              key: ValueKey('slot-remove-${slot.time}'),
              tooltip: l10n.removeTime,
              icon: const Icon(Icons.close),
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}

/// A label/value row that opens a picker ("Курс", "Часовой пояс").
class InfoRow extends StatelessWidget {
  /// Creates the row.
  const InfoRow({
    required this.label,
    required this.value,
    this.onTap,
    this.trailing,
    super.key,
  });

  /// Left label.
  final String label;

  /// Right value.
  final String value;

  /// Tap handler (null: read-only).
  final VoidCallback? onTap;

  /// Optional trailing widget (e.g. a clear button).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 54),
        child: Row(
          children: [
            Expanded(child: Text(label, style: textTheme.bodyLarge)),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: textTheme.titleSmall,
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}
