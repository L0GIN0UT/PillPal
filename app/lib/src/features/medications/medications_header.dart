import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../common/clamped_text.dart';
import '../common/gap.dart';
import '../common/pillpal_icon_button.dart';
import '../family/profile_context.dart';
import '../family/profile_menu_button.dart';

/// The header of the medication list (boards B-Medications and
/// B2-EmptyMedications): the title (clamped at x1.5), «+» as a round button
/// with a ring and the profile button of the person shown.
///
/// From the compact text scale on (x1.6) the actions leave the title's line
/// and sit on their own, right-aligned, under it (B2-README section 9.3).
/// A pushed list of someone else's medications has a back button instead of
/// the profile button. Keys: `medications-title`, `medications-add`,
/// `medications-back`.
class MedicationsHeader extends ConsumerWidget {
  /// Creates the header.
  const MedicationsHeader({
    required this.title,
    required this.pushed,
    required this.addRoute,
    super.key,
  });

  /// "Лекарства", or the medications of the person whose list it is.
  final String title;

  /// A list pushed above the tabs: a back button, no profile button.
  final bool pushed;

  /// Where «+» goes, or null for no «+» (the role does not allow it, or the
  /// empty list offers the action itself).
  final String? addRoute;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final compact =
        MediaQuery.textScalerOf(context).scale(1) >= PillPalSizes.compactScale;
    final route = addRoute;
    // The profile button exists only with someone else to switch to; without
    // it there is nothing to move under the title.
    final showProfile = !pushed &&
        (ref.watch(accessibleProfilesProvider).valueOrNull?.length ?? 0) >= 2;
    final actions = [
      if (route != null)
        PillPalIconButton.secondary(
          key: const Key('medications-add'),
          tooltip: l10n.addMedication,
          icon: Icons.add,
          onPressed: () => context.push(route),
        ),
      if (showProfile) const ProfileMenuButton(),
    ];
    // «+» and the profile button side by side, a gap between them.
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const Gap.h(PillPalSpacing.sm),
          actions[i],
        ],
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (pushed) ...[
              PillPalIconButton(
                key: const Key('medications-back'),
                icon: Icons.arrow_back,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => context.pop(),
              ),
              const Gap.h(PillPalSpacing.xs),
            ],
            Expanded(
              child: ClampedText(
                title,
                key: const Key('medications-title'),
                maxScale: PillPalSizes.titleMaxScale,
                style: Theme.of(context).textTheme.displaySmall,
              ),
            ),
            if (!compact) row,
          ],
        ),
        if (compact && actions.isNotEmpty)
          Align(alignment: AlignmentDirectional.centerEnd, child: row),
      ],
    );
  }
}
