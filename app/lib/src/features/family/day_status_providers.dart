import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../common/local_time.dart';
import '../today/today_state.dart';
import 'profile_context.dart';
import 'profile_day_summary.dart';

/// How a profile's day reads on the Family tab: the numbers, the zone their
/// times are shown in, and how old the data is when that is worth saying.
@immutable
class ProfileDayStatus {
  /// Creates the status.
  const ProfileDayStatus({
    required this.summary,
    required this.zone,
    this.staleAge,
  });

  /// Today's doses in numbers.
  final ProfileDaySummary summary;

  /// The profile's zone: the next dose is shown in it (D4).
  final String zone;

  /// Non-null when the data is old enough that the numbers may be wrong.
  final Duration? staleAge;

  @override
  bool operator ==(Object other) =>
      other is ProfileDayStatus &&
      other.summary == summary &&
      other.zone == zone &&
      other.staleAge == staleAge;

  @override
  int get hashCode => Object.hash(summary, zone, staleAge);
}

/// When this device last synced successfully (persisted, so it is known
/// right after a cold start offline); re-read after every sync.
final viewerLastSyncProvider = FutureProvider.autoDispose<DateTime?>((ref) {
  ref.watch(syncStatusProvider.select((status) => status.lastSuccessAt));
  return ref.watch(syncStateStoreProvider).lastSyncedAt();
});

/// Today's status of profile [profileId] for the Family tab, from the local
/// database alone (no request): the day view's doses through the same
/// privacy projection, recomputed whenever sync changes the tables.
///
/// Null while loading, for a profile the account has no access to, and for
/// an archive (it keeps its own pill). A `hidden` medication never counts:
/// the server does not deliver it to projected roles, and it is dropped here
/// too, so a late or odd row cannot change the numbers.
final profileDayStatusProvider =
    Provider.autoDispose.family<ProfileDayStatus?, String>((ref, profileId) {
  final access = ref.watch(profileAccessProvider(profileId)).valueOrNull;
  final today = ref.watch(todayStateProvider(profileId)).valueOrNull;
  if (access == null || access.archived || today == null) {
    return null;
  }
  final zone = access.localZone(ref.watch(deviceTimeZoneProvider));
  final doses = [
    for (final dose in today.doses)
      if (!(access.isProjected && dose.medication.privacy == 'hidden')) dose,
  ];
  return ProfileDayStatus(
    summary: profileDaySummary(doses, today.now, zone),
    zone: zone,
    staleAge: staleDataAge(
      now: today.now,
      ownerLastSeenAt: access.ownerLastSeenAt,
      lastSyncAt: ref.watch(viewerLastSyncProvider).valueOrNull,
    ),
  );
});
