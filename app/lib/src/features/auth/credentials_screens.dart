import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import 'auth_errors.dart';
import 'auth_fields.dart';
import 'auth_flow.dart';
import 'auth_session.dart';
import 'auth_widgets.dart';

/// What the credentials form submits; [name] is empty on sign-in.
typedef CredentialsInput = ({String name, String email, String password});

/// E-mail and password fields shared by registration and login; the
/// registration asks for the person's name first.
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

  /// Registration (step 1 of 3, the name and a new password) or sign-in.
  final bool registering;

  final Future<void> Function(CredentialsInput input) onSubmit;

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
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
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
    final nameError =
        widget.registering && flow.errorCode == AuthClientErrors.invalidName
            ? authErrorMessage(l10n, AuthClientErrors.invalidName)
            : null;
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
        // A name error belongs to the name field (below); in the banner it
        // would read as a problem of the e-mail or the password.
        AuthErrorBanner(code: nameError == null ? flow.errorCode : null),
        // Committed only by the explicit calls after a successful request.
        AutofillGroup(
          onDisposeAction: AutofillContextAction.cancel,
          child: Column(
            children: [
              if (widget.registering) ...[
                AuthNameField(
                  controller: _name,
                  errorText: nameError,
                  onChanged: (_) => controller.clearError(),
                ),
                const Gap.v(PillPalSpacing.lg),
              ],
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
        // No region line while region selection is hidden (Q5, owner
        // 2026-11-11); where data is stored is in the privacy policy.
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
    unawaited(
      widget.onSubmit(
        (name: _name.text, email: _email.text, password: _password.text),
      ),
    );
  }
}

/// Registration step 1 of 3: the name, e-mail and password, checked on the
/// device. The consents come next and «Create account» there sends the
/// request.
class RegisterScreen extends ConsumerWidget {
  /// Creates the screen.
  const RegisterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return _CredentialsForm(
      title: l10n.registerTitle,
      subtitle: l10n.registerSubtitle,
      submitLabel: l10n.registerAction,
      passwordHint: l10n.passwordHint(AuthLimits.passwordMin),
      registering: true,
      onSubmit: (input) async {
        final held = ref.read(authFlowProvider.notifier).continueRegistration(
              name: input.name,
              email: input.email,
              password: input.password,
            );
        if (held && context.mounted) {
          unawaited(context.push<void>(AppRoutes.registerConsent));
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
      onSubmit: (input) async {
        final outcome = await ref
            .read(authFlowProvider.notifier)
            .login(email: input.email, password: input.password);
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
