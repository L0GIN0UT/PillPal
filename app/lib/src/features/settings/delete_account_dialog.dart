import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/relatives_dto.dart';
import '../auth/auth_errors.dart';
import '../auth/auth_flow.dart';
import '../auth/auth_session.dart';
import '../family/family_providers.dart';
import '../family/profile_context.dart';
import 'deletion_fates.dart';

/// "Удалить аккаунт": opens the deletion dialog.
class DeleteAccountButton extends StatelessWidget {
  /// Creates the button.
  const DeleteAccountButton({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = Theme.of(context).colorScheme.error;
    return TextButton.icon(
      key: const Key('delete-account'),
      style: TextButton.styleFrom(foregroundColor: error),
      onPressed: () => unawaited(
        showDialog<void>(
          context: context,
          builder: (context) => const DeleteAccountDialog(),
        ),
      ),
      icon: const Icon(Icons.delete_forever_outlined),
      label: Text(l10n.deleteAccount),
    );
  }
}

/// Deletion with every disclosure of ADR 0010 §4: the grace period, that
/// relatives lose access at once, what becomes of managed profiles, and the
/// way back. Confirmed with the password; success signs this device out.
class DeleteAccountDialog extends ConsumerStatefulWidget {
  /// Creates the dialog.
  const DeleteAccountDialog({super.key});

  @override
  ConsumerState<DeleteAccountDialog> createState() =>
      _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends ConsumerState<DeleteAccountDialog> {
  final TextEditingController _password = TextEditingController();
  String? _errorCode;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final error = Theme.of(context).colorScheme.error;
    return AlertDialog(
      title: Text(l10n.deleteAccountTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ..._consequences(l10n, textTheme),
            if (_errorCode != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  authErrorMessage(l10n, _errorCode!),
                  key: const Key('delete-account-error'),
                  style: textTheme.bodyMedium?.copyWith(color: error),
                ),
              ),
            TextField(
              key: const Key('delete-account-password'),
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              onChanged: (_) => setState(() => _errorCode = null),
              decoration: InputDecoration(labelText: l10n.passwordLabel),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('delete-account-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        TextButton(
          key: const Key('delete-account-confirm'),
          style: TextButton.styleFrom(foregroundColor: error),
          onPressed: _busy ? null : _submit,
          child: Text(l10n.deleteAccountConfirm),
        ),
      ],
    );
  }

  /// Every consequence of ADR 0010 §4, with the terms the server states
  /// (the grace period, the archive retention), never constants of the app.
  List<Widget> _consequences(AppLocalizations l10n, TextTheme textTheme) {
    final terms = ref.watch(accountFeaturesProvider).valueOrNull ??
        const AccountFeatures();
    final fates = managedProfileFates(
      profiles: ref.watch(accessibleProfilesProvider).valueOrNull ?? const [],
      links: ref.watch(grantLinksProvider).valueOrNull ?? const [],
    );
    final retention = terms.managedArchiveRetentionDays;
    final points = [
      l10n.deleteAccountGrace(terms.accountDeletionGraceDays),
      l10n.deleteAccountRelatives,
      if (fates.isNotEmpty) ...[
        l10n.deleteAccountManagedTitle,
        for (final fate in fates)
          if (!fate.archived)
            l10n.deleteAccountManagedErased(fate.name)
          else if (retention == null)
            l10n.deleteAccountManagedArchivedLimited(fate.name)
          else
            l10n.deleteAccountManagedArchived(fate.name, retention),
      ],
      if (fates.any((fate) => fate.archived)) l10n.deleteAccountNotes,
      l10n.deleteAccountRestore,
    ];
    return [
      for (final point in points) ...[
        Text(point, style: textTheme.bodyMedium),
        const SizedBox(height: 10),
      ],
    ];
  }

  Future<void> _submit() async {
    if (_password.text.isEmpty) {
      setState(() => _errorCode = 'invalid_password');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(authSessionProvider.notifier)
          .deleteAccount(_password.text);
    } on ApiException catch (error) {
      _fail(error.code);
    } on Exception {
      _fail(AuthClientErrors.generic);
    }
    // On success the router leaves the app for onboarding and this dialog
    // goes away with it.
  }

  void _fail(String code) {
    if (mounted) {
      setState(() {
        _busy = false;
        _errorCode = code;
      });
    }
  }
}
