import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../common/profile_chips.dart';
import 'profile_context.dart';
import 'profile_picker.dart';

/// "Whose medications" under the title of a tab: [ProfileChips] wired to the
/// accessible profiles and the selected one. Today only: the Family tab lists
/// every profile itself and has no switcher, and History and Medications keep
/// `ProfileSwitcher` until they move. Nothing is shown while there is only the
/// own profile.
///
/// The row is drawn for the page background; the key is `profile-switcher`,
/// the chips are `profile-switch-<id>`.
class ProfileChipsBar extends ConsumerWidget {
  /// Creates the bar.
  const ProfileChipsBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final picker = ProfilePicker.of(
      ref.watch(accessibleProfilesProvider).valueOrNull,
      ref.watch(selectedProfileIdProvider),
      meLabel: l10n.profileMe,
    );
    if (picker == null) {
      return const SizedBox.shrink();
    }
    final controller = ref.read(selectedProfileIdProvider.notifier);
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.md),
      child: ProfileChips(
        key: const Key('profile-switcher'),
        profiles: picker.items,
        selectedId: picker.currentId,
        onSelected: (id) => controller.select(picker.selectionOf(id)),
      ),
    );
  }
}
