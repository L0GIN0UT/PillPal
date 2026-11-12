import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/relatives_dto.dart';
import '../../data/db/database.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/clamped_text.dart';
import '../common/gap.dart';
import '../common/person_row.dart';
import '../common/pillpal_banner.dart';
import '../common/pillpal_card.dart';
import '../common/stacked_buttons.dart';
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
    final muted = textTheme.bodyLarge?.copyWith(
      color: context.palette.inkMuted,
    );
    final inviter = preview.inviterDisplayName ?? l10n.relativeUnnamed;
    final managed = preview.profileKind == 'managed';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: PillPalAvatar(name: inviter, size: PillPalSizes.avatarLg),
        ),
        const Gap.v(PillPalSpacing.lg),
        ClampedText(
          l10n.invitePreviewTitle(inviter),
          key: const Key('invite-preview-title'),
          maxScale: PillPalSizes.titleMaxScale,
          style: textTheme.headlineMedium,
        ),
        const Gap.v(PillPalSpacing.sm),
        Text(
          managed
              ? l10n.invitePreviewManaged(preview.profileDisplayName)
              : l10n.invitePreviewSelf(inviter),
          style: muted,
        ),
        const Gap.v(PillPalSpacing.xs),
        Text(
          '${roleLabel(l10n, preview.role)}. '
          '${roleExplanation(l10n, preview.role)}',
          key: const Key('invite-preview-role'),
          style: muted,
        ),
        const Gap.v(PillPalSpacing.xl),
        _SeesList(
          role: preview.role,
          whose: managed ? preview.profileDisplayName : inviter,
        ),
        if (preview.role == ScopeRole.guardian) _guardianWarning(context),
        if (errorCode != null) ...[
          const Gap.v(PillPalSpacing.md),
          PillPalBanner(
            tone: BannerTone.danger,
            liveRegion: true,
            body: relativesErrorMessage(l10n, errorCode!),
            bodyKey: const Key('accept-error'),
          ),
        ],
        const Gap.v(PillPalSpacing.md),
        Text(l10n.acceptNotNotified(inviter), style: textTheme.bodySmall),
        const Gap.v(PillPalSpacing.xl),
        StackedButtons(
          children: [
            FilledButton(
              key: const Key('accept-confirm'),
              onPressed: busy ? null : onAccept,
              child: Text(l10n.acceptInviteConfirm),
            ),
            OutlinedButton(
              key: const Key('accept-decline'),
              onPressed: busy ? null : onDecline,
              child: Text(l10n.acceptInviteDecline),
            ),
          ],
        ),
      ],
    );
  }

  Widget _guardianWarning(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: PillPalSpacing.md),
      // Informative, not destructive or blocking: danger is not for it (D3).
      child: PillPalBanner(
        key: const Key('guardian-warning'),
        tone: BannerTone.info,
        icon: Icons.warning_amber_outlined,
        body: l10n.guardianWarning,
      ),
    );
  }
}

/// What the invitee will see and be able to do, one line each with an icon
/// (board B2-InviteAccept). It follows the role: a viewer changes nothing, an
/// editor changes `shared` medications, a guardian sees everything.
class _SeesList extends StatelessWidget {
  const _SeesList({required this.role, required this.whose});

  final String role;

  /// The person whose medications these are.
  final String whose;

  List<(IconData, String)> _points(AppLocalizations l10n) {
    final alerts = (Icons.notifications_outlined, l10n.acceptSeesAlerts);
    final anonymous = (Icons.visibility_off_outlined, l10n.acceptSeesAnonymous);
    return switch (role) {
      ScopeRole.guardian => [
          (Icons.visibility_outlined, l10n.acceptSeesEverything),
          alerts,
        ],
      ScopeRole.editor => [
          (Icons.visibility_outlined, l10n.acceptSeesMedications(whose)),
          anonymous,
          alerts,
          (Icons.edit_outlined, l10n.acceptCanEdit),
        ],
      _ => [
          (Icons.visibility_outlined, l10n.acceptSeesMedications(whose)),
          anonymous,
          alerts,
          (Icons.lock_outline, l10n.acceptReadOnly),
        ],
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final style = Theme.of(context).textTheme.bodyLarge;
    return PillPalCard(
      key: const Key('invite-preview-sees'),
      child: Column(
        children: [
          for (final (index, point) in _points(l10n).indexed)
            Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : PillPalSpacing.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      top: PillPalSpacing.xs,
                      end: PillPalSpacing.md,
                    ),
                    child: Icon(
                      point.$1,
                      size: PillPalSizes.iconInline,
                      color: palette.inkMuted,
                    ),
                  ),
                  Expanded(child: Text(point.$2, style: style)),
                ],
              ),
            ),
        ],
      ),
    );
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
        ClampedText(
          l10n.inviteAcceptedTitle(grant.profileDisplayName),
          key: const Key('invite-accepted'),
          maxScale: PillPalSizes.titleMaxScale,
          style: textTheme.headlineMedium,
        ),
        const Gap.v(PillPalSpacing.sm),
        Text(l10n.inviteAcceptedHint, style: textTheme.bodyLarge),
        const Gap.v(PillPalSpacing.xl),
        StackedButtons(
          children: [
            FilledButton(
              key: const Key('accepted-open'),
              onPressed: () => context
                  .pushReplacement(AppRoutes.profileToday(grant.profileId)),
              child: Text(l10n.openProfile),
            ),
            OutlinedButton(
              key: const Key('accepted-done'),
              onPressed: () => context.pop(),
              child: Text(l10n.done),
            ),
          ],
        ),
      ],
    );
  }
}
