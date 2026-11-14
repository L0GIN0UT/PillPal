import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/clamped_text.dart';
import '../common/confirm_dialog.dart';
import '../common/error_snack_bar.dart';
import '../common/gap.dart';
import '../common/stacked_buttons.dart';
import 'danger_text_button.dart';
import 'family_providers.dart';
import 'family_tiles.dart';

/// What the owner learns when a code is accepted. [linkId] and [name] are
/// known only when exactly one new link appeared since the code was made;
/// otherwise the view says it without a name and offers no revoke.
@immutable
class AcceptedRelative {
  /// Creates the result.
  const AcceptedRelative({required this.role, this.linkId, this.name});

  /// The role the code granted.
  final String role;

  /// The new link, when it is certain which one it is.
  final String? linkId;

  /// The new relative's name, when known.
  final String? name;
}

/// The owner's confirmation that the code was scanned: «{name} теперь в
/// ваших близких» (announced) with the role granted, «Готово», and «Это не
/// он? Отозвать» in case the wrong person scanned it.
class RelativeAddedView extends ConsumerStatefulWidget {
  /// Creates the view.
  const RelativeAddedView({
    required this.accepted,
    required this.onDone,
    super.key,
  });

  /// Who joined, as far as known.
  final AcceptedRelative accepted;

  /// Leaves the screen (also after a revoke).
  final VoidCallback onDone;

  @override
  ConsumerState<RelativeAddedView> createState() => _RelativeAddedState();
}

class _RelativeAddedState extends ConsumerState<RelativeAddedView> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final accepted = widget.accepted;
    final name = accepted.name;
    final title = name == null || accepted.linkId == null
        ? l10n.addRelativeSuccessUnnamed
        : l10n.addRelativeSuccess(name);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          Icons.check_circle_outline,
          size: PillPalSizes.iconEmpty,
          color: context.palette.action,
        ),
        const Gap.v(PillPalSpacing.lg),
        Semantics(
          liveRegion: true,
          child: ClampedText(
            title,
            key: const Key('relative-added'),
            maxScale: PillPalSizes.titleMaxScale,
            style: textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
        ),
        const Gap.v(PillPalSpacing.sm),
        Text(
          l10n.relativeAddedRole(roleLabel(l10n, accepted.role).toLowerCase()),
          key: const Key('relative-added-role'),
          style: textTheme.bodyLarge?.copyWith(color: context.palette.inkMuted),
          textAlign: TextAlign.center,
        ),
        const Gap.v(PillPalSpacing.xl),
        StackedButtons(
          children: [
            FilledButton(
              key: const Key('relative-added-done'),
              onPressed: _busy ? null : widget.onDone,
              child: Text(l10n.done),
            ),
          ],
        ),
        if (accepted.linkId != null) ...[
          const Gap.v(PillPalSpacing.sm),
          Center(
            child: dangerTextButton(
              context,
              key: const Key('relative-added-revoke'),
              onPressed: _busy ? null : () => unawaited(_revoke()),
              label: l10n.relativeAddedRevoke,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _revoke() async {
    final linkId = widget.accepted.linkId;
    if (linkId == null) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final confirmed = await confirmAction(
      context,
      title: l10n.revokeTitle(widget.accepted.name ?? l10n.relativeUnnamed),
      body: l10n.revokeBody,
      confirmLabel: l10n.revokeAccess,
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(familyActionsProvider).revoke(linkId);
      if (mounted) {
        widget.onDone();
      }
    } on Exception {
      if (mounted) {
        setState(() => _busy = false);
        showErrorSnackBar(context);
      }
    }
  }
}
