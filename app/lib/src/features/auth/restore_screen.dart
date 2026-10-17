import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../common/formatters.dart';
import '../common/local_time.dart';
import 'auth_flow.dart';
import 'auth_widgets.dart';

/// Restore of an account in its deletion grace period (ADR 0010 §2): the
/// login answered `account_pending_deletion` and mailed a code; the code and
/// the ticket kept in memory restore the account and sign in.
class RestoreScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const RestoreScreen({super.key});

  @override
  ConsumerState<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends ConsumerState<RestoreScreen> {
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
    final pending = flow.restore;
    if (pending == null) {
      // The ticket is gone (the app was restarted): sign in again.
      return AuthScaffold(
        title: l10n.restoreTitle,
        children: [
          Text(l10n.restoreTicketLost, key: const Key('restore-lost')),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('restore-back'),
            onPressed: () => context.go(AppRoutes.login),
            child: Text(l10n.loginAction),
          ),
        ],
      );
    }
    final tz = ref.watch(deviceTimeZoneProvider);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final eraseDay = wallClockOf(pending.eraseAfter, tz).date;
    return AuthScaffold(
      title: l10n.restoreTitle,
      subtitle: l10n.restoreSubtitle(
        formatLongDate(eraseDay, locale),
        flow.email ?? '',
      ),
      children: [
        AuthErrorBanner(code: flow.errorCode),
        TextField(
          key: const Key('restore-code'),
          controller: _code,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          maxLength: AuthLimits.codeLength,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => ref.read(authFlowProvider.notifier).clearError(),
          onSubmitted: (_) => _submit(),
          style: Theme.of(context).textTheme.headlineMedium,
          decoration: InputDecoration(labelText: l10n.codeLabel),
        ),
        const SizedBox(height: 16),
        BusyButton(
          key: const Key('restore-submit'),
          label: l10n.restoreAction,
          busy: flow.busy,
          onPressed: _submit,
        ),
      ],
    );
  }

  void _submit() {
    if (ref.read(authFlowProvider).busy) {
      return;
    }
    FocusScope.of(context).unfocus();
    unawaited(ref.read(authFlowProvider.notifier).restoreAccount(_code.text));
  }
}
