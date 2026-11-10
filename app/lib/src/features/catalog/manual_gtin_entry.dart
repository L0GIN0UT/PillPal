import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../common/stacked_buttons.dart';

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
///
/// A number that does not pass is a blocking error: `danger` is used for it
/// and only for it (the field border, the icon and the text, B2-README
/// principle 3). With [onCamera] a «Камера» button goes back to the camera.
class ManualGtinEntry extends StatefulWidget {
  /// Creates the entry; [onGtin] gets the valid GTIN-14.
  const ManualGtinEntry({required this.onGtin, this.onCamera, super.key});

  /// Called with the number once it is valid.
  final ValueChanged<String> onGtin;

  /// Goes back to the camera; null when there is no camera to go back to.
  final VoidCallback? onCamera;

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
    final message = _errorText(l10n);
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
            error: message == null ? null : _ErrorLine(message),
          ),
        ),
        const Gap.v(PillPalSpacing.xl),
        _buttons(l10n),
      ],
    );
  }

  /// Camera and Continue side by side; stacked, Continue first, once the
  /// text is large (section 9.6).
  Widget _buttons(AppLocalizations l10n) {
    final camera = widget.onCamera;
    final submit = FilledButton(
      key: const Key('scan-manual-submit'),
      onPressed: _submit,
      child: Text(l10n.scanManualSubmit, textAlign: TextAlign.center),
    );
    if (camera == null) {
      return submit;
    }
    final label = Text(l10n.scanUseCamera, textAlign: TextAlign.center);
    if (context.stacksPair) {
      return StackedButtons(
        children: [
          submit,
          OutlinedButton.icon(
            key: const Key('scan-use-camera'),
            onPressed: camera,
            icon: const Icon(Icons.photo_camera_outlined),
            label: label,
          ),
        ],
      );
    }
    // Side by side each button is about 130 px wide at 320 px: no icon and a
    // narrower padding, so a one-word label never breaks in the middle.
    const narrow = ButtonStyle(
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: PillPalSpacing.md),
      ),
    );
    final back = OutlinedButton(
      key: const Key('scan-use-camera'),
      onPressed: camera,
      style: narrow,
      child: label,
    );
    return Row(
      children: [
        Expanded(child: back),
        const Gap.h(PillPalSpacing.md),
        Expanded(
          child: FilledButton(
            key: const Key('scan-manual-submit'),
            onPressed: _submit,
            style: narrow,
            child: Text(l10n.scanManualSubmit, textAlign: TextAlign.center),
          ),
        ),
      ],
    );
  }
}

/// The error under the field: an icon and the words in `danger`, so the
/// problem is not told by colour alone.
class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The style the field theme gives its errors, so icon and text match.
    final style =
        theme.inputDecorationTheme.errorStyle ?? theme.textTheme.bodySmall;
    final color = context.palette.danger;
    return Row(
      key: const Key('scan-manual-error'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The icon grows with the text, like the words beside it.
        Icon(
          Icons.error_outline,
          size: MediaQuery.textScalerOf(context).scale(
            style?.fontSize ?? kDefaultFontSize,
          ),
          color: color,
        ),
        const Gap.h(PillPalSpacing.xs),
        Expanded(child: Text(message, style: style?.copyWith(color: color))),
      ],
    );
  }
}
