import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../common/choice_button.dart';
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
    // Wrapping chips (like the settings): the names must fit senior mode.
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        key: const Key('profile-switcher'),
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final access in profiles)
            ChoiceButton(
              key: ValueKey('profile-switch-${access.id}'),
              label: access.isOwnSelf
                  ? l10n.profileMe
                  : access.profile.displayName,
              selected:
                  access.isOwnSelf ? selected == null : selected == access.id,
              onTap: () =>
                  controller.select(access.isOwnSelf ? null : access.id),
            ),
        ],
      ),
    );
  }
}
