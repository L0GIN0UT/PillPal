import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import 'auth_fields.dart';
import 'auth_flow.dart';
import 'auth_widgets.dart';

/// Enter the 6-digit code mailed after registration; success signs in and
/// the router moves on to Today.
class VerifyScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const VerifyScreen({super.key});

  @override
  ConsumerState<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends ConsumerState<VerifyScreen> {
  final TextEditingController _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final flow = ref.watch(authFlowProvider);
    final controller = ref.read(authFlowProvider.notifier);
    return AuthScaffold(
      title: l10n.verifyTitle,
      subtitle: l10n.verifySubtitle(flow.email ?? ''),
      // «Step 3 of 3» only after a registration, not after a sign-in that
      // needs a code.
      stepNumber: flow.registering ? RegistrationStep.code.number : null,
      stepCount: flow.registering ? RegistrationStep.total : null,
      actions: [
        BusyButton(
          key: const Key('auth-submit'),
          label: l10n.verifyAction,
          busy: flow.busy,
          onPressed: _submit,
        ),
      ],
      children: [
        AuthErrorBanner(code: flow.errorCode),
        AuthCodeField(
          fieldKey: const Key('auth-code'),
          controller: _code,
          onChanged: (_) => controller.clearError(),
          onSubmitted: _submit,
        ),
        const Gap.v(PillPalSpacing.md),
        AuthResendButton(
          buttonKey: const Key('auth-resend'),
          busy: flow.busy,
          onResend: controller.resendCode,
        ),
      ],
    );
  }

  void _submit() {
    // The keyboard's "done" bypasses the disabled button.
    if (ref.read(authFlowProvider).busy) {
      return;
    }
    FocusScope.of(context).unfocus();
    unawaited(ref.read(authFlowProvider.notifier).verify(_code.text));
  }
}
