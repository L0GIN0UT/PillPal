import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../common/pillpal_icon_button.dart';

/// E-mail field of the onboarding screens: a leading envelope, the e-mail
/// keyboard and the autofill hint (B2 board SignIn).
class AuthEmailField extends StatelessWidget {
  /// Creates the field.
  const AuthEmailField({
    required this.controller,
    required this.onChanged,
    super.key,
  });

  /// Holds the address.
  final TextEditingController controller;

  /// Called on every edit.
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const Key('auth-email'),
      controller: controller,
      keyboardType: TextInputType.emailAddress,
      autofillHints: const [AutofillHints.email],
      autocorrect: false,
      textInputAction: TextInputAction.next,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: AppLocalizations.of(context).emailLabel,
        prefixIcon: const Icon(Icons.mail_outline),
      ),
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
    super.key,
  });

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

  @override
  State<AuthPasswordField> createState() => _AuthPasswordFieldState();
}

class _AuthPasswordFieldState extends State<AuthPasswordField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return TextField(
      key: const Key('auth-password'),
      controller: widget.controller,
      obscureText: _hidden,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: [widget.autofillHint],
      onChanged: widget.onChanged,
      onSubmitted: (_) => widget.onSubmitted(),
      decoration: InputDecoration(
        labelText: l10n.passwordLabel,
        helperText: widget.helperText,
        prefixIcon: const Icon(Icons.lock_outline),
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
