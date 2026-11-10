import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal/src/data/api/account_dto.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/features/doses/dose_providers.dart';
import 'package:pillpal/src/features/family/family_overview.dart';
import 'package:pillpal/src/features/family/family_providers.dart';
import 'package:pillpal/src/features/family/profile_context.dart';
import 'package:pillpal/src/push/push_providers.dart';
import 'package:pillpal/src/push/push_service.dart';
import 'package:pillpal/src/reminders/providers.dart';
import 'package:pillpal/src/reminders/reminder_status.dart';

// Synthetic data and provider overrides of the Family tab tests.

class _FixedPush extends PushStatusNotifier {
  _FixedPush(this._status);

  final PushStatus _status;

  @override
  PushStatus build() => _status;
}

class _FixedReminders extends ReminderStatusNotifier {
  @override
  ReminderStatus build() => const ReminderStatus();
}

class _NoActions extends FamilyActions {
  _NoActions(super.ref);

  @override
  Future<void> refresh({bool quiet = true}) async {}
}

ProfileRow familyProfile(String id, String kind, String name) => ProfileRow(
      id: id,
      kind: kind,
      displayName: name,
      timezone: 'Asia/Tokyo',
      clientUpdatedAt: 1,
      updatedByDevice: 'test-device',
      missedAlertMinutes: 30,
      missedAlertsEnabled: true,
    );

RelativeLinkRow familyLink(
  String id, {
  String direction = LinkDirection.outgoing,
  String profileKind = 'self',
  String? counterpart,
  bool active = true,
}) =>
    RelativeLinkRow(
      id: id,
      direction: direction,
      profileId: 'profile-$id',
      role: 'viewer',
      counterpartName: counterpart,
      active: active,
      notifyMissed: true,
      createdAt: DateTime.utc(2026, 10, 10).microsecondsSinceEpoch,
      profileName: 'Grace Longname Profile',
      profileKind: profileKind,
    );

final ProfileAccess familyOwn = ProfileAccess(
  profile: familyProfile('self-1', 'self', 'Test User'),
  role: 'owner',
);
final ProfileAccess familyWard = ProfileAccess(
  profile: familyProfile('ward-1', 'managed', 'Pat Ward With A Long Name'),
  role: 'owner',
);
final ProfileAccess familyArchive = ProfileAccess(
  profile: familyProfile('ward-2', 'managed', 'Sam Archive'),
  role: 'guardian',
  archived: true,
  archivePurgeAfter: DateTime.utc(2026, 12, 1),
);
final ProfileAccess familyForeign = ProfileAccess(
  profile: familyProfile('foreign-1', 'self', 'Grace Foreign'),
  role: 'viewer',
  ownerLastSeenAt: DateTime.utc(2026, 11, 1, 9),
);

/// Everything the Family tab lists: a new relative, a relative of a managed
/// profile, an inactive link, someone I see, a ward and an archive.
FamilyOverview familyFullOverview() => FamilyOverview(
      seeMe: [
        familyLink('new', counterpart: 'Alex Relative Longname'),
        familyLink('out-managed', profileKind: 'managed'),
        familyLink('out-paused', counterpart: 'Robin', active: false),
      ],
      iSee: [
        familyLink(
          'in-1',
          direction: LinkDirection.incoming,
          counterpart: 'Grace',
        ),
      ],
      wards: [familyWard, familyArchive],
    );

const FamilyOverview familyNobody =
    FamilyOverview(seeMe: [], iSee: [], wards: []);

/// Wraps [child] in the providers of the Family tab, fixed by the test.
Widget familyScope(
  Widget child, {
  FamilyOverview? overview,
  List<RelativeLinkRow> fresh = const [],
  AccountFeatures features = const AccountFeatures(),
  bool pushHint = true,
}) {
  final shown = overview ?? familyFullOverview();
  final everyone = [familyOwn, ...shown.wards, familyForeign];
  return ProviderScope(
    overrides: [
      familyOverviewProvider.overrideWithValue(AsyncData(shown)),
      newRelativesProvider.overrideWithValue(fresh),
      selfProfileProvider
          .overrideWith((ref) => Stream.value(familyOwn.profile)),
      accountFeaturesProvider.overrideWith((ref) async => features),
      accessibleProfilesProvider.overrideWith((ref) => Stream.value(everyone)),
      accessScopesProvider.overrideWith((ref) => Stream.value(const [])),
      pushStatusProvider.overrideWith(
        () => _FixedPush(
          pushHint
              ? const PushStatus(PushAvailability.unavailable)
              : PushStatus.idle,
        ),
      ),
      reminderStatusProvider.overrideWith(_FixedReminders.new),
      familyActionsProvider.overrideWith(_NoActions.new),
      deviceTimeZoneProvider.overrideWithValue('Europe/Moscow'),
    ],
    child: SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: child,
    ),
  );
}
