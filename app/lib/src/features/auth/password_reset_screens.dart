import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import 'auth_fields.dart';
import 'auth_flow.dart';
import 'auth_widgets.dart';

/// Password reset, step 1: the address the code is mailed to. The server
/// answers the same for unknown addresses, so this screen moves on to the
/// code screen whatever the account state is (no account enumeration).
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  /// Creates the screen; [email] is what the sign-in form already holds.
  const ForgotPasswordScreen({this.email, super.key});

  /// Prefilled address.
  final String? email;

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  late final TextEditingController _email =
      TextEditingController(text: widget.email);

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final flow = ref.watch(authFlowProvider);
    return AuthScaffold(
      title: l10n.forgotTitle,
      subtitle: l10n.forgotSubtitle,
      actions: [
        BusyButton(
          key: const Key('forgot-submit'),
          label: l10n.sendResetCode,
          busy: flow.busy,
          onPressed: _submit,
        ),
      ],
      children: [
        AuthErrorBanner(code: flow.errorCode),
        AuthEmailField(
          controller: _email,
          onChanged: (_) => ref.read(authFlowProvider.notifier).clearError(),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (ref.read(authFlowProvider).busy) {
      return;
    }
    FocusScope.of(context).unfocus();
    final sent = await ref
        .read(authFlowProvider.notifier)
        .requestPasswordReset(_email.text);
    if (sent && mounted) {
      unawaited(context.push<void>(AppRoutes.resetPassword));
    }
  }
}

/// Password reset, step 2: the mailed code and the new password. On success
/// the user is signed in through the ordinary login path.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _resent = false;

  @override
  void dispose() {
    // Nothing secret outlives the screen.
    _code.clear();
    _password.clear();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final flow = ref.watch(authFlowProvider);
    final controller = ref.read(authFlowProvider.notifier);
    return AuthScaffold(
      title: l10n.resetTitle,
      actions: [
        BusyButton(
          key: const Key('reset-submit'),
          label: l10n.resetAction,
          busy: flow.busy,
          onPressed: _submit,
        ),
      ],
      children: [
        // The same words for every address (no enumeration).
        AuthNotice(key: const Key('reset-sent'), text: l10n.passwordResetSent),
        AuthErrorBanner(code: flow.errorCode),
        AutofillGroup(
          child: Column(
            children: [
              AuthCodeField(
                fieldKey: const Key('reset-code'),
                controller: _code,
                onChanged: (_) => controller.clearError(),
                onSubmitted: () {},
              ),
              const Gap.v(PillPalSpacing.lg),
              AuthPasswordField(
                controller: _password,
                label: l10n.newPassword,
                autofillHint: AutofillHints.newPassword,
                helperText: l10n.resetPasswordRule(AuthLimits.passwordMin),
                onChanged: (_) => controller.clearError(),
                onSubmitted: _submit,
              ),
            ],
          ),
        ),
        const Gap.v(PillPalSpacing.md),
        TextButton(
          key: const Key('reset-resend'),
          onPressed: flow.busy ? null : _resend,
          child: Text(_resent ? l10n.codeResent : l10n.resendCode),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (ref.read(authFlowProvider).busy) {
      return;
    }
    FocusScope.of(context).unfocus();
    final result = await ref
        .read(authFlowProvider.notifier)
        .resetPassword(code: _code.text, newPassword: _password.text);
    if (!result.changed) {
      return;
    }
    if (result.login == LoginOutcome.signedIn) {
      // Offers the password manager to save the new credentials.
      TextInput.finishAutofillContext();
    }
    // Signed in, the router has already closed this screen (and `dispose`
    // cleared the fields).
    if (!mounted) {
      return;
    }
    // The new password is spent: never keep it in a field.
    _code.clear();
    _password.clear();
    switch (result.login) {
      case LoginOutcome.needsVerification:
        unawaited(context.push<void>(AppRoutes.verify));
      case LoginOutcome.needsRestore:
        unawaited(context.push<void>(AppRoutes.restore));
      case LoginOutcome.failed || LoginOutcome.signedIn:
        // Changed, but signing in failed: the sign-in form shows why.
        context.go(AppRoutes.login);
    }
  }

  Future<void> _resend() async {
    final email = ref.read(authFlowProvider).email;
    if (email == null) {
      return;
    }
    final sent =
        await ref.read(authFlowProvider.notifier).requestPasswordReset(email);
    if (mounted) {
      setState(() => _resent = sent);
    }
  }
}
