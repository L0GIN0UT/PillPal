import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../auth/auth_fields.dart';
import '../auth/auth_flow_state.dart';
import '../auth/auth_widgets.dart';
import '../common/gap.dart';
import 'account_section.dart';
import 'change_password_controller.dart';

/// Change of the password (board B2-ChangePassword, Settings -> Account):
/// step 1 asks for the current password and mails a code; step 2 takes the
/// code and the new password. The current password is cleared when the change
/// ends, when the screen closes and when the app leaves the foreground.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final TextEditingController _new = TextEditingController();
  final FocusNode _newFocus = FocusNode();
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    // Nothing secret outlives the screen (the controller wipes its copy as
    // its provider goes away).
    _current.clear();
    _code.clear();
    _new.clear();
    _current.dispose();
    _code.dispose();
    _new.dispose();
    _newFocus.dispose();
    super.dispose();
  }

  void _onLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.detached) {
      return;
    }
    // paused, hidden or inactive: the password must not wait in memory (or
    // in a field) while another app is in front.
    _current.clear();
    ref.read(changePasswordProvider.notifier).wipe();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(changePasswordProvider.select((state) => state.step), (_, step) {
      if (step == ChangePasswordStep.done) {
        context.pop();
      }
    });
    final flow = ref.watch(changePasswordProvider);
    return flow.step == ChangePasswordStep.current
        ? _currentStep(context, flow)
        : _codeStep(context, flow);
  }

  Widget _currentStep(BuildContext context, ChangePasswordState flow) {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(changePasswordProvider.notifier);
    return AuthScaffold(
      title: l10n.changePasswordTitle,
      subtitle: l10n.changePasswordIntro,
      actions: [
        BusyButton(
          key: const Key('change-password-next'),
          label: l10n.changePasswordSendCode,
          busy: flow.busy,
          onPressed: _sendCode,
        ),
      ],
      children: [
        AuthErrorBanner(code: flow.errorCode),
        if (flow.wiped) AuthNotice(text: l10n.changePasswordWiped),
        AuthPasswordField(
          fieldKey: const Key('change-password-current'),
          controller: _current,
          label: l10n.currentPasswordLabel,
          autofillHint: AutofillHints.password,
          onChanged: (_) => controller.clearError(),
          onSubmitted: _sendCode,
        ),
      ],
    );
  }

  Widget _codeStep(BuildContext context, ChangePasswordState flow) {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(changePasswordProvider.notifier);
    return AuthScaffold(
      title: l10n.changePasswordTitle,
      subtitle: l10n.changePasswordCodeSent(AuthLimits.codeTtlMinutes),
      actions: [
        BusyButton(
          key: const Key('change-password-submit'),
          label: l10n.changePasswordSave,
          busy: flow.busy,
          onPressed: _save,
        ),
      ],
      children: [
        AuthErrorBanner(code: flow.errorCode),
        AutofillGroup(
          onDisposeAction: AutofillContextAction.cancel,
          child: Column(
            children: [
              AuthCodeField(
                fieldKey: const Key('change-password-code'),
                controller: _code,
                onChanged: (_) => controller.clearError(),
                onSubmitted: _newFocus.requestFocus,
              ),
              const Gap.v(PillPalSpacing.lg),
              AuthPasswordField(
                fieldKey: const Key('change-password-new'),
                controller: _new,
                focusNode: _newFocus,
                label: l10n.newPassword,
                autofillHint: AutofillHints.newPassword,
                helperText: l10n.changePasswordRule(AuthLimits.passwordMin),
                onChanged: (_) => controller.clearError(),
                onSubmitted: _save,
              ),
            ],
          ),
        ),
        const Gap.v(PillPalSpacing.md),
        AuthResendButton(
          buttonKey: const Key('change-password-resend'),
          busy: flow.busy,
          onResend: controller.resend,
        ),
        if (flow.offersReset)
          TextButton(
            key: const Key('change-password-forgot'),
            onPressed: () => unawaited(_forgot(context)),
            child: Text(l10n.forgotPassword),
          ),
      ],
    );
  }

  Future<void> _sendCode() async {
    if (ref.read(changePasswordProvider).busy) {
      return;
    }
    FocusScope.of(context).unfocus();
    final sent = await ref
        .read(changePasswordProvider.notifier)
        .requestCode(_current.text);
    if (sent && mounted) {
      // The controller holds it now, until the change ends.
      _current.clear();
    }
  }

  Future<void> _save() async {
    if (ref.read(changePasswordProvider).busy) {
      return;
    }
    FocusScope.of(context).unfocus();
    final changed = await ref
        .read(changePasswordProvider.notifier)
        .confirm(code: _code.text, newPassword: _new.text);
    if (changed) {
      TextInput.finishAutofillContext();
    }
  }

  /// The reset flow is for signed-out users: leave the account first.
  Future<void> _forgot(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return confirmSignOut(
      context,
      ref,
      title: l10n.changePasswordForgotTitle,
      body: l10n.changePasswordForgotBody,
    );
  }
}
