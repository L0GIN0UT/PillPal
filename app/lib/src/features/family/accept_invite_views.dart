import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/relatives_dto.dart';
import '../../data/db/database.dart';
import '../../routing/routes.dart';
import 'family_tiles.dart';
import 'relatives_errors.dart';

/// What the invitee sees before confirming: who invited them, to what, with
/// which role, and for a guardian the warning. Nothing has changed yet.
class InvitePreviewView extends StatelessWidget {
  /// Creates the preview of [preview].
  const InvitePreviewView({
    required this.preview,
    required this.busy,
    required this.errorCode,
    required this.onAccept,
    required this.onDecline,
    super.key,
  });

  /// The invite as the server describes it.
  final InvitePreview preview;

  /// A request is running: the buttons are off.
  final bool busy;

  /// The last failure, if any.
  final String? errorCode;

  /// The explicit confirmation.
  final VoidCallback onAccept;

  /// "Not now": leaves the screen.
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final inviter = preview.inviterDisplayName ?? l10n.relativeUnnamed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.invitePreviewTitle(inviter),
          key: const Key('invite-preview-title'),
          style: textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(
          preview.profileKind == 'managed'
              ? l10n.invitePreviewManaged(preview.profileDisplayName)
              : l10n.invitePreviewSelf(inviter),
          style: textTheme.bodyLarge,
        ),
        const SizedBox(height: 8),
        Text(
          '${roleLabel(l10n, preview.role)}. '
          '${roleExplanation(l10n, preview.role)}',
          key: const Key('invite-preview-role'),
          style: textTheme.bodyLarge,
        ),
        if (preview.role == ScopeRole.guardian) _guardianWarning(context),
        if (errorCode != null) ...[
          const SizedBox(height: 12),
          Text(
            relativesErrorMessage(l10n, errorCode!),
            key: const Key('accept-error'),
          ),
        ],
        const SizedBox(height: 20),
        ..._buttons(l10n),
      ],
    );
  }

  Widget _guardianWarning(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        key: const Key('guardian-warning'),
        color: colors.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            l10n.guardianWarning,
            style: textTheme.bodyLarge?.copyWith(
              color: colors.onErrorContainer,
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buttons(AppLocalizations l10n) {
    return [
      FilledButton(
        key: const Key('accept-confirm'),
        onPressed: busy ? null : onAccept,
        child: Text(l10n.acceptInviteConfirm),
      ),
      const SizedBox(height: 8),
      TextButton(
        key: const Key('accept-decline'),
        onPressed: busy ? null : onDecline,
        child: Text(l10n.acceptInviteDecline),
      ),
    ];
  }
}

/// The confirmation after accepting: open the profile or finish.
class InviteAcceptedView extends StatelessWidget {
  /// Creates the view for the new [grant].
  const InviteAcceptedView({required this.grant, super.key});

  /// The grant the invitee now holds.
  final IncomingGrant grant;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.inviteAcceptedTitle(grant.profileDisplayName),
          key: const Key('invite-accepted'),
          style: textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(l10n.inviteAcceptedHint, style: textTheme.bodyLarge),
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('accepted-open'),
          onPressed: () =>
              context.pushReplacement(AppRoutes.profileToday(grant.profileId)),
          child: Text(l10n.openProfile),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('accepted-done'),
          onPressed: () => context.pop(),
          child: Text(l10n.done),
        ),
      ],
    );
  }
}
