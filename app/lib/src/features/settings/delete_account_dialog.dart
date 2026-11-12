import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/relatives_dto.dart';
import '../../theme/spacing.dart';
import '../auth/auth_errors.dart';
import '../auth/auth_flow.dart';
import '../auth/auth_session.dart';
import '../common/banner_tone.dart';
import '../common/gap.dart';
import '../common/list_row.dart';
import '../common/pillpal_banner.dart';
import '../common/pillpal_dialog.dart';
import '../common/show_pillpal_dialog.dart';
import '../family/family_providers.dart';
import '../family/profile_context.dart';
import 'deletion_fates.dart';

/// "Удалить аккаунт": the one destructive row of the account card (danger
/// title and tile, B2-DangerDialog); opens the deletion dialog.
class DeleteAccountButton extends StatelessWidget {
  /// Creates the row.
  const DeleteAccountButton({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PillPalListRow(
      key: const Key('delete-account'),
      title: l10n.deleteAccount,
      leadingIcon: Icons.delete_forever_outlined,
      destructive: true,
      onTap: () => unawaited(
        showPillPalDialog<void>(
          context: context,
          builder: (context) => const DeleteAccountDialog(),
        ),
      ),
    );
  }
}

/// Deletion with every disclosure of ADR 0010 §4: the grace period, that
/// relatives lose access at once, what becomes of managed profiles, and the
/// way back. Confirmed with the password; success signs this device out.
///
/// A [lead] is a sentence that says why this dialog opened, such as the
/// withdrawal of the health data consent, which is a deletion request; it comes
/// before the grace period.
class DeleteAccountDialog extends ConsumerStatefulWidget {
  /// Creates the dialog.
  const DeleteAccountDialog({this.lead, super.key});

  /// Why the dialog opened; nothing before the grace period when null.
  final String? lead;

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
    final (grace, consequences) = _disclosures(l10n);
    return PillPalDialog(
      destructive: true,
      title: l10n.deleteAccountTitle,
      body: widget.lead == null ? grace : '${widget.lead}\n\n$grace',
      consequences: consequences,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_errorCode != null) ...[
            PillPalBanner(
              tone: BannerTone.danger,
              body: authErrorMessage(l10n, _errorCode!),
              bodyKey: const Key('delete-account-error'),
              liveRegion: true,
            ),
            const Gap.v(PillPalSpacing.md),
          ],
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
      // The destructive button first, as wide as the dialog (B2-DangerDialog).
      choices: [
        DialogChoice(
          key: const Key('delete-account-confirm'),
          label: l10n.deleteAccountConfirm,
          kind: DialogChoiceKind.destructive,
          busy: _busy,
          onPressed: _busy ? null : _submit,
        ),
        DialogChoice(
          key: const Key('delete-account-cancel'),
          label: l10n.cancel,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  /// The grace period as the lead sentence and every other consequence of
  /// ADR 0010 §4 as a list, with the terms the server states (the grace
  /// period, the archive retention), never constants of the app.
  (String, List<String>) _disclosures(AppLocalizations l10n) {
    final terms = ref.watch(accountFeaturesProvider).valueOrNull ??
        const AccountFeatures();
    final fates = managedProfileFates(
      profiles: ref.watch(accessibleProfilesProvider).valueOrNull ?? const [],
      links: ref.watch(grantLinksProvider).valueOrNull ?? const [],
    );
    final retention = terms.managedArchiveRetentionDays;
    return (
      l10n.deleteAccountGrace(terms.accountDeletionGraceDays),
      [
        l10n.deleteAccountRelatives,
        if (fates.isNotEmpty) ...[
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
      ],
    );
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
