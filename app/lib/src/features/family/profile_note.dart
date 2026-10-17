import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../common/local_time.dart';
import 'profile_context.dart';

/// Small notes under the header of another person's profile: whose time
/// zone the times are in (D4) and, for a relative's own profile, around
/// which hour their phone last synced (D5; the server floors it to the
/// hour).
class ProfileNote extends ConsumerWidget {
  /// Creates the notes for [access] (not the user's own profile).
  const ProfileNote({required this.access, super.key});

  /// The profile shown.
  final ProfileAccess access;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final deviceZone = ref.watch(deviceTimeZoneProvider);
    final zone = access.profile.timezone;
    final lastSeen = access.ownerLastSeenAt;
    final notes = <Widget>[
      if (zone != deviceZone)
        Text(
          l10n.profileZoneNote(zone),
          key: const Key('profile-zone-note'),
          style: textTheme.bodySmall,
        ),
      if (lastSeen != null)
        Text(
          l10n.ownerLastSyncNote(wallClockOf(lastSeen, deviceZone).hhmm),
          key: const Key('profile-last-sync-note'),
          style: textTheme.bodySmall,
        ),
    ];
    if (notes.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: notes,
      ),
    );
  }
}
