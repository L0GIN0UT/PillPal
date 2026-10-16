import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../common/error_snack_bar.dart';
import '../common/formatters.dart';
import 'stock_level.dart';
import 'stock_providers.dart';

/// Longest stock amount typed: 9 integer digits, a separator, 3 decimals.
const int _maxStockInput = 13;

final RegExp _stockInput = RegExp(r'^(0|[1-9][0-9]{0,8})([.,][0-9]{1,3})?$');

/// "Осталось: 24 таблетки · на 12 дней", or why it cannot be computed;
/// null when stock is not tracked.
String? stockStatusText(
  AppLocalizations l10n,
  StockLevel level,
  String locale,
) {
  return switch (level) {
    StockNotTracked() => null,
    StockUnknown(problem: StockProblem.unknownUnit) => l10n.stockUnknownUnit,
    StockUnknown(problem: StockProblem.unitMismatch) => l10n.stockUnitMismatch,
    StockUnknown(problem: StockProblem.unknownIntakeDose) =>
      l10n.stockUnknownIntakeDose,
    final StockKnown known => _knownText(l10n, known, locale),
  };
}

String _knownText(AppLocalizations l10n, StockKnown level, String locale) {
  final left = l10n.stockLeft(
    formatDose(l10n, level.remaining, level.unit.name, locale),
  );
  final days = level.daysLeft;
  return days == null ? left : '$left · ${l10n.stockDaysLeft(days)}';
}

/// The stock line and the "Пополнить запас" button of the medication screen.
class StockStatusSection extends ConsumerWidget {
  /// Creates the section.
  const StockStatusSection({required this.medicationId, super.key});

  /// The medication (stock tracked).
  final String medicationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final level = ref.watch(stockLevelProvider(medicationId));
    final text = stockStatusText(l10n, level, locale);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (text != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              text,
              key: const Key('med-stock-status'),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        OutlinedButton.icon(
          key: const Key('med-stock-refill'),
          onPressed: () => showRefillDialog(context, ref, medicationId),
          icon: const Icon(Icons.add_shopping_cart_outlined),
          label: Text(l10n.refillStock),
        ),
      ],
    );
  }
}

/// Asks for the freshly counted stock and saves it as the new baseline.
Future<void> showRefillDialog(
  BuildContext context,
  WidgetRef ref,
  String medicationId,
) async {
  final count = await showDialog<String>(
    context: context,
    builder: (context) => const _RefillDialog(),
  );
  if (count == null || !context.mounted) {
    return;
  }
  try {
    await ref.read(stockActionsProvider).setStock(medicationId, count);
  } on Object {
    if (context.mounted) {
      showErrorSnackBar(context);
    }
  }
}

class _RefillDialog extends StatefulWidget {
  const _RefillDialog();

  @override
  State<_RefillDialog> createState() => _RefillDialogState();
}

class _RefillDialogState extends State<_RefillDialog> {
  final TextEditingController _count = TextEditingController();
  bool _invalid = false;

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _count.text.trim();
    if (!_stockInput.hasMatch(text)) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(text.replaceAll(',', '.'));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.refillTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.refillHint),
          const SizedBox(height: 12),
          TextField(
            key: const Key('refill-count'),
            controller: _count,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              LengthLimitingTextInputFormatter(_maxStockInput),
            ],
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: l10n.stockCountLabel,
              errorText: _invalid ? l10n.invalidNumber : null,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('refill-save'),
          onPressed: _submit,
          child: Text(l10n.save),
        ),
      ],
    );
  }
}
