import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../common/beside_or_below.dart';
import '../common/clamped_text.dart';

/// The header of the Family tab (board B-Family): the title (clamped at
/// x1.5, B2-README section 9.2) and «Пригласить» as the primary action.
/// From the compact text scale on (x1.6), and on a screen too narrow for the
/// title and the button on one line, the button moves under the title,
/// right-aligned (section 9.3). [onInvite] null draws the title alone.
class FamilyHeader extends StatelessWidget {
  /// Creates the header.
  const FamilyHeader({required this.onInvite, super.key});

  /// Opens the invite screen, or null when nobody can be invited now.
  final VoidCallback? onInvite;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final compact =
        MediaQuery.textScalerOf(context).scale(1) >= PillPalSizes.compactScale;
    final title = ClampedText(
      l10n.familyTitle,
      key: const Key('family-title'),
      maxScale: PillPalSizes.titleMaxScale,
      style: Theme.of(context).textTheme.displaySmall,
    );
    final invite = onInvite;
    if (invite == null) {
      return title;
    }
    final button = FilledButton.icon(
      key: const Key('invite-self'),
      onPressed: invite,
      icon: const Icon(Icons.person_add_alt_1),
      label: Text(l10n.inviteShort),
    );
    // The button leaves the title's line when the title would not fit
    // beside it on one line (a narrow screen), and always from x1.6.
    return BesideOrBelow(
      below: compact,
      main: title,
      trailing: button,
    );
  }
}
