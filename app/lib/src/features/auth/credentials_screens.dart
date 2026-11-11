import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/providers.dart';
import '../../routing/routes.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import 'auth_fields.dart';
import 'auth_flow.dart';
import 'auth_session.dart';
import 'auth_widgets.dart';

/// E-mail and password fields shared by registration and login.
class _CredentialsForm extends ConsumerStatefulWidget {
  const _CredentialsForm({
    required this.title,
    required this.subtitle,
    required this.submitLabel,
    required this.passwordHint,
    required this.registering,
    required this.onSubmit,
    this.initialEmail,
    this.passwordChanged = false,
  });

  final String title;
  final String subtitle;
  final String submitLabel;
  final String? passwordHint;

  /// Registration (a step of two, a new password) or sign-in.
  final bool registering;

  final Future<void> Function(String email, String password) onSubmit;

  /// Address to prefill (the sign-in after a password reset).
  final String? initialEmail;

  /// Shows the «password changed» notice above the error banner.
  final bool passwordChanged;

  @override
  ConsumerState<_CredentialsForm> createState() => _CredentialsFormState();
}

class _CredentialsFormState extends ConsumerState<_CredentialsForm> {
  late final TextEditingController _email =
      TextEditingController(text: widget.initialEmail);
  final TextEditingController _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final flow = ref.watch(authFlowProvider);
    final controller = ref.read(authFlowProvider.notifier);
    final hasLocalData =
        ref.watch(hasBoundLocalDataProvider).valueOrNull ?? false;
    return AuthScaffold(
      title: widget.title,
      subtitle: widget.subtitle,
      stepNumber:
          widget.registering ? RegistrationStep.credentials.number : null,
      stepCount: widget.registering ? RegistrationStep.total : null,
      actions: [
        BusyButton(
          key: const Key('auth-submit'),
          label: widget.submitLabel,
          busy: flow.busy,
          onPressed: _submit,
        ),
      ],
      children: [
        // Signing in as another account erases this device's data.
        if (hasLocalData)
          AuthNotice(
            key: const Key('other-account-warning'),
            text: l10n.otherAccountWarning,
          ),
        if (widget.passwordChanged)
          AuthNotice(
            key: const Key('password-changed'),
            text: l10n.passwordChangedNotice,
          ),
        AuthErrorBanner(code: flow.errorCode),
        // Committed only by the explicit calls after a successful request.
        AutofillGroup(
          onDisposeAction: AutofillContextAction.cancel,
          child: Column(
            children: [
              AuthEmailField(
                controller: _email,
                onChanged: (_) => controller.clearError(),
              ),
              const Gap.v(PillPalSpacing.lg),
              AuthPasswordField(
                controller: _password,
                autofillHint: widget.registering
                    ? AutofillHints.newPassword
                    : AutofillHints.password,
                helperText: widget.passwordHint,
                onChanged: (_) => controller.clearError(),
                onSubmitted: _submit,
              ),
              if (!widget.registering)
                Align(
                  // Text edge on the field text (B2-SignIn).
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    key: const Key('auth-forgot'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsetsDirectional.symmetric(
                        horizontal: PillPalSpacing.lg,
                      ),
                    ),
                    onPressed: flow.busy ? null : _forgot,
                    child: Text(l10n.forgotPassword),
                  ),
                ),
            ],
          ),
        ),
        // Where the data will live, as a statement, not a choice (Q5).
        if (widget.registering) ...[
          const Gap.v(PillPalSpacing.lg),
          AuthNotice(
            key: const Key('data-location'),
            icon: Icons.public,
            text: switch (DataRegion.fromWire(
              ref.watch(apiConfigProvider).region,
            )) {
              DataRegion.ru => l10n.regionRuHint,
              DataRegion.eu => l10n.regionEuHint,
            },
          ),
        ],
      ],
    );
  }

  void _forgot() {
    ref.read(authFlowProvider.notifier).clearError();
    unawaited(context.push<void>(AppRoutes.forgotPassword, extra: _email.text));
  }

  void _submit() {
    // The keyboard's "done" bypasses the disabled button.
    if (ref.read(authFlowProvider).busy) {
      return;
    }
    FocusScope.of(context).unfocus();
    unawaited(widget.onSubmit(_email.text, _password.text));
  }
}

/// Registration with e-mail and password; a code is mailed next.
class RegisterScreen extends ConsumerWidget {
  /// Creates the screen.
  const RegisterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    return _CredentialsForm(
      title: l10n.registerTitle,
      subtitle: l10n.registerSubtitle,
      submitLabel: l10n.registerAction,
      passwordHint: l10n.passwordHint(AuthLimits.passwordMin),
      registering: true,
      onSubmit: (email, password) async {
        final sent = await ref.read(authFlowProvider.notifier).register(
              email: email,
              password: password,
              locale: locale,
            );
        if (sent) {
          // Offers the password manager to save the new credentials.
          TextInput.finishAutofillContext();
        }
        if (sent && context.mounted) {
          unawaited(context.push<void>(AppRoutes.verify));
        }
      },
    );
  }
}

/// Sign-in with e-mail and password.
class LoginScreen extends ConsumerWidget {
  /// Creates the screen; [args] come from the password reset.
  const LoginScreen({this.args, super.key});

  /// Prefilled address and the «password changed» notice, if any.
  final LoginRouteArgs? args;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return _CredentialsForm(
      title: l10n.loginTitle,
      subtitle: l10n.loginSubtitle,
      submitLabel: l10n.loginAction,
      passwordHint: null,
      registering: false,
      initialEmail: args?.email,
      passwordChanged: args?.passwordChanged ?? false,
      onSubmit: (email, password) async {
        final outcome = await ref
            .read(authFlowProvider.notifier)
            .login(email: email, password: password);
        if (outcome == LoginOutcome.signedIn) {
          TextInput.finishAutofillContext();
        }
        if (!context.mounted) {
          return;
        }
        if (outcome == LoginOutcome.needsVerification) {
          unawaited(context.push<void>(AppRoutes.verify));
        } else if (outcome == LoginOutcome.needsRestore) {
          unawaited(context.push<void>(AppRoutes.restore));
        }
      },
    );
  }
}
