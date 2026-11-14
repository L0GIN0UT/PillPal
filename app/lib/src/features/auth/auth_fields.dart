import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/repositories/validation.dart';
import '../common/pillpal_icon_button.dart';
import 'auth_flow.dart';

/// E-mail field of the onboarding screens: a leading envelope, the e-mail
/// keyboard and the autofill hint (B2 board SignIn).
class AuthEmailField extends StatelessWidget {
  /// Creates the field.
  const AuthEmailField({
    required this.controller,
    required this.onChanged,
    this.onSubmitted,
    super.key,
  });

  /// Holds the address.
  final TextEditingController controller;

  /// Called on every edit.
  final ValueChanged<String> onChanged;

  /// Called by the keyboard's "done"; without it the key moves on ("next").
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const Key('auth-email'),
      controller: controller,
      keyboardType: TextInputType.emailAddress,
      autofillHints: const [AutofillHints.email],
      autocorrect: false,
      textInputAction:
          onSubmitted == null ? TextInputAction.next : TextInputAction.done,
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: AppLocalizations.of(context).emailLabel,
        prefixIcon: const Icon(Icons.mail_outline),
      ),
    );
  }
}

/// The person's own name (registration and Settings): what relatives see, so
/// the hint says so. Capitalised words, the name autofill hint and at most
/// [FieldLimits.personNameMax] code points, counted like the validator; the
/// rest of the rule (`isPersonName`) is checked on submit.
class AuthNameField extends StatelessWidget {
  /// Creates the field.
  const AuthNameField({
    required this.controller,
    required this.onChanged,
    this.onSubmitted,
    this.enabled = true,
    this.errorText,
    this.fieldKey = const Key('auth-name'),
    super.key,
  });

  /// Whether the field takes input (off while there is nothing to rename).
  final bool enabled;

  /// An error shown under the field instead of the hint.
  final String? errorText;

  /// Key of the text field; a screen with its own journeys passes its own.
  final Key fieldKey;

  /// Holds the name.
  final TextEditingController controller;

  /// Called on every edit.
  final ValueChanged<String> onChanged;

  /// Called by the keyboard's "done"; without it the key moves on ("next").
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return TextField(
      key: fieldKey,
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.name,
      textCapitalization: TextCapitalization.words,
      autofillHints: const [AutofillHints.name],
      inputFormatters: [
        const CodePointLimitFormatter(FieldLimits.personNameMax),
      ],
      textInputAction:
          onSubmitted == null ? TextInputAction.next : TextInputAction.done,
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: l10n.personNameLabel,
        helperText: l10n.personNameHint,
        // The hint may wrap on narrow screens and with large text.
        helperMaxLines: 3,
        errorText: errorText,
        errorMaxLines: 3,
        prefixIcon: const Icon(Icons.person_outline),
      ),
    );
  }
}

/// Cuts the text to [max] Unicode code points (Python's `len()`, as the
/// server counts), unlike [LengthLimitingTextInputFormatter], which counts
/// grapheme clusters. Whole code points only: a surrogate pair is never split.
class CodePointLimitFormatter extends TextInputFormatter {
  /// Creates the formatter.
  const CodePointLimitFormatter(this.max);

  /// The most code points the text may have.
  final int max;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final runes = newValue.text.runes;
    if (runes.length <= max) {
      return newValue;
    }
    final text = String.fromCharCodes(runes.take(max));
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Password field: hidden by default with a show/hide button, never
/// prefilled, no suggestions. [autofillHint] is `newPassword` when the user
/// chooses one and `password` when they enter an existing one.
class AuthPasswordField extends StatefulWidget {
  /// Creates the field.
  const AuthPasswordField({
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    required this.autofillHint,
    this.helperText,
    this.label,
    this.focusNode,
    this.maxLength,
    this.fieldKey = const Key('auth-password'),
    super.key,
  });

  /// Key of the text field; a screen with its own journeys passes its own.
  final Key fieldKey;

  /// Holds the password; the caller keeps it empty at the start.
  final TextEditingController controller;

  /// Called on every edit.
  final ValueChanged<String> onChanged;

  /// Called by the keyboard's "done".
  final VoidCallback onSubmitted;

  /// `AutofillHints.newPassword` or `AutofillHints.password`.
  final String autofillHint;

  /// Rule shown under the field.
  final String? helperText;

  /// Label; the plain «Password» when null.
  final String? label;

  /// Focus of the field, when the screen moves to it.
  final FocusNode? focusNode;

  /// The most characters the field takes (the server's limit); no limit when
  /// null.
  final int? maxLength;

  @override
  State<AuthPasswordField> createState() => _AuthPasswordFieldState();
}

class _AuthPasswordFieldState extends State<AuthPasswordField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return TextField(
      key: widget.fieldKey,
      controller: widget.controller,
      focusNode: widget.focusNode,
      obscureText: _hidden,
      autocorrect: false,
      enableSuggestions: false,
      inputFormatters: [
        if (widget.maxLength != null)
          LengthLimitingTextInputFormatter(widget.maxLength),
      ],
      autofillHints: [widget.autofillHint],
      onChanged: widget.onChanged,
      onSubmitted: (_) => widget.onSubmitted(),
      decoration: InputDecoration(
        labelText: widget.label ?? l10n.passwordLabel,
        helperText: widget.helperText,
        suffixIcon: PillPalIconButton(
          key: const Key('auth-password-toggle'),
          icon: _hidden
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
          tooltip: _hidden ? l10n.showPassword : l10n.hidePassword,
          onPressed: () => setState(() => _hidden = !_hidden),
        ),
      ),
    );
  }
}

/// Field for the 6-digit code mailed to the user (verify and restore): digits
/// only, the one-time-code autofill hint and large numerals. The screen passes
/// its own [fieldKey].
class AuthCodeField extends StatelessWidget {
  /// Creates the field.
  const AuthCodeField({
    required this.fieldKey,
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    this.focusNode,
    super.key,
  });

  /// Focus of the field, when the screen moves it on.
  final FocusNode? focusNode;

  /// Key of the text field (the journeys find it).
  final Key fieldKey;

  /// Holds the code.
  final TextEditingController controller;

  /// Called on every edit.
  final ValueChanged<String> onChanged;

  /// Called by the keyboard's done action.
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      controller: controller,
      focusNode: focusNode,
      keyboardType: TextInputType.number,
      autofillHints: const [AutofillHints.oneTimeCode],
      maxLength: AuthLimits.codeLength,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: onChanged,
      onSubmitted: (_) => onSubmitted(),
      style: Theme.of(context).textTheme.headlineMedium,
      decoration: InputDecoration(
        labelText: AppLocalizations.of(context).codeLabel,
      ),
    );
  }
}
