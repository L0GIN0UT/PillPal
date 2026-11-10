import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';

/// The GTIN-14 of [input], or the reason it is not a valid number
/// (`docs/spec/gtin.md` section 1: length, characters, check digit).
({String? gtin14, GtinErrorCode? error}) checkTypedGtin(String input) {
  try {
    return (gtin14: normalizeGtin(input).gtin14, error: null);
  } on GtinException catch (error) {
    return (gtin14: null, error: error.code);
  }
}

/// Typing the number printed under a barcode: the fallback of every scan
/// problem. The check digit is verified before anything is used, so a typo
/// never reaches the catalog.
class ManualGtinEntry extends StatefulWidget {
  /// Creates the entry; [onGtin] gets the valid GTIN-14.
  const ManualGtinEntry({required this.onGtin, super.key});

  /// Called with the number once it is valid.
  final ValueChanged<String> onGtin;

  @override
  State<ManualGtinEntry> createState() => _ManualGtinEntryState();
}

class _ManualGtinEntryState extends State<ManualGtinEntry> {
  // Digits, spaces and hyphens as printed; the longest form is a GTIN-14
  // with separators.
  static final RegExp _allowed = RegExp(r'[0-9 \-]');
  static const int _maxChars = 24;

  final TextEditingController _text = TextEditingController();
  GtinErrorCode? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final checked = checkTypedGtin(_text.text);
    final gtin14 = checked.gtin14;
    if (gtin14 == null) {
      setState(() => _error = checked.error);
      return;
    }
    widget.onGtin(gtin14);
  }

  String? _errorText(AppLocalizations l10n) {
    switch (_error) {
      case null:
        return null;
      case GtinErrorCode.invalidCharacters:
        return l10n.scanManualErrorCharacters;
      case GtinErrorCode.invalidCheckDigit:
        return l10n.scanManualErrorCheckDigit;
      case GtinErrorCode.invalidLength:
      case GtinErrorCode.unsupportedFormat:
        return l10n.scanManualErrorLength;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('scan-manual-field'),
          controller: _text,
          autofocus: true,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          inputFormatters: [
            FilteringTextInputFormatter.allow(_allowed),
            LengthLimitingTextInputFormatter(_maxChars),
          ],
          onChanged: (_) {
            if (_error != null) {
              setState(() => _error = null);
            }
          },
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: l10n.scanManualLabel,
            helperText: l10n.scanManualHelper,
            errorText: _errorText(l10n),
          ),
        ),
        const Gap.v(PillPalSpacing.md),
        FilledButton(
          key: const Key('scan-manual-submit'),
          onPressed: _submit,
          child: Text(l10n.scanManualSubmit),
        ),
      ],
    );
  }
}
