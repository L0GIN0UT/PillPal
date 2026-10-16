import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
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
  bool _resent = false;

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
      children: [
        AuthErrorBanner(code: flow.errorCode),
        TextField(
          key: const Key('auth-code'),
          controller: _code,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          maxLength: AuthLimits.codeLength,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => controller.clearError(),
          onSubmitted: (_) => _submit(),
          style: Theme.of(context).textTheme.headlineMedium,
          decoration: InputDecoration(labelText: l10n.codeLabel),
        ),
        const SizedBox(height: 16),
        BusyButton(
          key: const Key('auth-submit'),
          label: l10n.verifyAction,
          busy: flow.busy,
          onPressed: _submit,
        ),
        const SizedBox(height: 12),
        TextButton(
          key: const Key('auth-resend'),
          onPressed: flow.busy ? null : _resend,
          child: Text(_resent ? l10n.codeResent : l10n.resendCode),
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

  Future<void> _resend() async {
    final sent = await ref.read(authFlowProvider.notifier).resendCode();
    if (mounted) {
      setState(() => _resent = sent);
    }
  }
}
