import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../common/profile_chips.dart';
import 'profile_context.dart';

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
    final profiles = ref.watch(accessibleProfilesProvider).valueOrNull;
    if (profiles == null || profiles.length < 2) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final selected = ref.watch(selectedProfileIdProvider);
    final controller = ref.read(selectedProfileIdProvider.notifier);
    // The own profile is selected while nothing else is (null).
    final own = profiles.where((a) => a.isOwnSelf).map((a) => a.id).firstOrNull;
    final current = selected != null && profiles.any((a) => a.id == selected)
        ? selected
        : own ?? profiles.first.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.md),
      child: ProfileChips(
        key: const Key('profile-switcher'),
        profiles: [
          for (final access in profiles)
            ProfileChipItem(
              id: access.id,
              label: access.isOwnSelf
                  ? l10n.profileMe
                  : access.profile.displayName,
            ),
        ],
        selectedId: current,
        onSelected: (id) => controller.select(id == own ? null : id),
      ),
    );
  }
}
