import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../common/formatters.dart';
import '../stock/stock_widgets.dart';

/// Typed stock amount: 9 integer digits, a separator and 3 decimals.
const int _maxStockInput = 13;

/// Typed low-stock threshold (0..365).
const int _maxDaysInput = 3;

/// "Учитывать остаток" on the medication form (TZ §2.4).
///
/// A first count is typed here; once the medication has a counted stock the
/// form shows what is left and "Пополнить запас" instead, so saving other
/// fields never moves the stock baseline (docs/adr/0004-stock-tracking.md).
class MedicationStockFields extends StatelessWidget {
  /// Creates the section.
  const MedicationStockFields({
    required this.medicationId,
    required this.tracking,
    required this.counted,
    required this.count,
    required this.unit,
    required this.lowStockDays,
    required this.onTracking,
    required this.onUnit,
    required this.onEdited,
    this.countHint,
    this.countError,
    this.unitError,
    this.daysError,
    super.key,
  });

  /// The medication; null while it is being created.
  final String? medicationId;

  /// Whether stock is tracked.
  final bool tracking;

  /// Whether the stored medication already has a counted stock.
  final bool counted;

  /// Stock amount field.
  final TextEditingController count;

  /// Stock unit (a dose unit's wire name, or legacy free text).
  final String unit;

  /// Low-stock threshold field.
  final TextEditingController lowStockDays;

  /// Tracking switched.
  final ValueChanged<bool> onTracking;

  /// Unit picked.
  final ValueChanged<String> onUnit;

  /// A text field changed (clears errors).
  final VoidCallback onEdited;

  /// Helper text of the count field (e.g. "count again for a new unit").
  final String? countHint;

  /// Error texts of the fields.
  final String? countError;

  /// See [countError].
  final String? unitError;

  /// See [countError].
  final String? daysError;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final id = medicationId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const Key('med-stock-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.trackStockTitle),
          subtitle: Text(l10n.trackStockHint),
          value: tracking,
          onChanged: onTracking,
        ),
        if (tracking) ...[
          if (counted && id != null) ...[
            StockStatusSection(medicationId: id),
            const SizedBox(height: 12),
          ] else
            _text(
              count,
              'med-stock-count',
              l10n.stockCountLabel,
              max: _maxStockInput,
              keyboard: const TextInputType.numberWithOptions(decimal: true),
              helper: countHint,
              error: countError,
            ),
          _unitPicker(l10n),
          const SizedBox(height: 12),
          _text(
            lowStockDays,
            'med-stock-days',
            l10n.lowStockDaysLabel,
            max: _maxDaysInput,
            keyboard: TextInputType.number,
            hint: l10n.lowStockDaysHint,
            error: daysError,
          ),
        ],
      ],
    );
  }

  Widget _unitPicker(AppLocalizations l10n) {
    final selected = DoseUnit.values.asNameMap()[unit];
    return DropdownButtonFormField<DoseUnit>(
      key: const Key('med-stock-unit'),
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: l10n.stockUnitLabel,
        errorText: unitError,
      ),
      items: [
        for (final value in DoseUnit.values)
          DropdownMenuItem(
            value: value,
            child: Text(doseUnitLabel(l10n, value, stockUnitDisplayCount)),
          ),
      ],
      onChanged: (value) {
        if (value != null) {
          onUnit(value.name);
        }
      },
    );
  }

  Widget _text(
    TextEditingController controller,
    String key,
    String label, {
    required int max,
    TextInputType? keyboard,
    String? hint,
    String? helper,
    String? error,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: Key(key),
        controller: controller,
        keyboardType: keyboard,
        inputFormatters: [LengthLimitingTextInputFormatter(max)],
        onChanged: (_) => onEdited(),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          helperMaxLines: 2,
          errorText: error,
          errorMaxLines: 3,
        ),
      ),
    );
  }
}

/// Plural form the unit list is shown in ("таблеток", "tablets").
const int stockUnitDisplayCount = 5;

/// The unit a newly tracked stock starts with.
const String defaultStockUnit = 'tablet';

/// The form's unit after tracking is switched on: kept when it is a dose
/// unit, otherwise [defaultStockUnit].
String stockUnitWhenTracking(String unit) =>
    DoseUnit.values.asNameMap().containsKey(unit) ? unit : defaultStockUnit;
