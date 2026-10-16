import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
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
    required this.onSubmit,
  });

  final String title;
  final String subtitle;
  final String submitLabel;
  final String? passwordHint;
  final Future<void> Function(String email, String password) onSubmit;

  @override
  ConsumerState<_CredentialsForm> createState() => _CredentialsFormState();
}

class _CredentialsFormState extends ConsumerState<_CredentialsForm> {
  final TextEditingController _email = TextEditingController();
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
      children: [
        // Signing in as another account erases this device's data.
        if (hasLocalData)
          AuthNotice(
            key: const Key('other-account-warning'),
            text: l10n.otherAccountWarning,
          ),
        AuthErrorBanner(code: flow.errorCode),
        TextField(
          key: const Key('auth-email'),
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          autocorrect: false,
          textInputAction: TextInputAction.next,
          onChanged: (_) => controller.clearError(),
          decoration: InputDecoration(labelText: l10n.emailLabel),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('auth-password'),
          controller: _password,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          onChanged: (_) => controller.clearError(),
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: l10n.passwordLabel,
            helperText: widget.passwordHint,
          ),
        ),
        const SizedBox(height: 24),
        BusyButton(
          key: const Key('auth-submit'),
          label: widget.submitLabel,
          busy: flow.busy,
          onPressed: _submit,
        ),
      ],
    );
  }

  void _submit() {
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
      onSubmit: (email, password) async {
        final sent = await ref.read(authFlowProvider.notifier).register(
              email: email,
              password: password,
              locale: locale,
            );
        if (sent && context.mounted) {
          unawaited(context.push<void>(AppRoutes.verify));
        }
      },
    );
  }
}

/// Sign-in with e-mail and password.
class LoginScreen extends ConsumerWidget {
  /// Creates the screen.
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return _CredentialsForm(
      title: l10n.loginTitle,
      subtitle: l10n.loginSubtitle,
      submitLabel: l10n.loginAction,
      passwordHint: null,
      onSubmit: (email, password) async {
        final outcome = await ref
            .read(authFlowProvider.notifier)
            .login(email: email, password: password);
        if (outcome == LoginOutcome.needsVerification && context.mounted) {
          unawaited(context.push<void>(AppRoutes.verify));
        }
      },
    );
  }
}
