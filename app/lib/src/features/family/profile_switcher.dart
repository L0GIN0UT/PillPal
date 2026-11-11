import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../common/choice_group.dart';
import 'profile_context.dart';

/// "Whose medications": switches Today, Medications and History between the
/// user's own profile, the profiles they run and the relatives' profiles
/// they may see. Not shown while there is only the own profile.
class ProfileSwitcher extends ConsumerWidget {
  /// Creates the switcher.
  const ProfileSwitcher({super.key});

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
    final options = {
      for (final access in profiles)
        access.id:
            access.isOwnSelf ? l10n.profileMe : access.profile.displayName,
    };
    final current = selected ?? own;
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.md),
      child: ChoiceGroup<String>.optional(
        key: const Key('profile-switcher'),
        options: options,
        selected: current,
        keyOf: (id) => ValueKey('profile-switch-$id'),
        onSelected: (id) => controller.select(id == own ? null : id),
      ),
    );
  }
}
