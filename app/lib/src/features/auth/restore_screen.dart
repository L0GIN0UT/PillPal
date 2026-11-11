import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../common/formatters.dart';
import '../common/local_time.dart';
import 'auth_fields.dart';
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
      return _ticketLost(l10n);
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
      actions: [
        BusyButton(
          key: const Key('restore-submit'),
          label: l10n.restoreAction,
          busy: flow.busy,
          onPressed: _submit,
        ),
      ],
      children: [
        AuthErrorBanner(code: flow.errorCode),
        AuthCodeField(
          fieldKey: const Key('restore-code'),
          controller: _code,
          onChanged: (_) => ref.read(authFlowProvider.notifier).clearError(),
          onSubmitted: _submit,
        ),
      ],
    );
  }

  /// The ticket is gone (the app was restarted): sign in again.
  Widget _ticketLost(AppLocalizations l10n) {
    return AuthScaffold(
      title: l10n.restoreTitle,
      actions: [
        FilledButton(
          key: const Key('restore-back'),
          onPressed: () => context.go(AppRoutes.login),
          child: Text(l10n.loginAction),
        ),
      ],
      children: [
        AuthNotice(
          key: const Key('restore-lost'),
          text: l10n.restoreTicketLost,
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
