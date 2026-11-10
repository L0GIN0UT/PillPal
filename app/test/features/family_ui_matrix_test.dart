import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/account_dto.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/features/doses/dose_providers.dart';
import 'package:pillpal/src/features/family/archived_profile_banner.dart';
import 'package:pillpal/src/features/family/family_overview.dart';
import 'package:pillpal/src/features/family/family_providers.dart';
import 'package:pillpal/src/features/family/family_screen.dart';
import 'package:pillpal/src/features/family/invite_disclosure.dart';
import 'package:pillpal/src/features/family/profile_context.dart';
import 'package:pillpal/src/features/family/profile_note.dart';
import 'package:pillpal/src/features/family/profile_switcher.dart';
import 'package:pillpal/src/push/push_providers.dart';
import 'package:pillpal/src/push/push_service.dart';
import 'package:pillpal/src/reminders/providers.dart';
import 'package:pillpal/src/reminders/reminder_status.dart';

import '../support/ui_matrix.dart';

// The Family tab and its parts in the whole UI matrix (docs/ui-pass-plan.md,
// UI-6a). Data is synthetic and the providers are fixed by the test.

class _FixedPush extends PushStatusNotifier {
  @override
  PushStatus build() => const PushStatus(PushAvailability.unavailable);
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

ProfileRow _profile(String id, String kind, String name) => ProfileRow(
      id: id,
      kind: kind,
      displayName: name,
      timezone: 'Asia/Tokyo',
      clientUpdatedAt: 1,
      updatedByDevice: 'test-device',
      missedAlertMinutes: 30,
      missedAlertsEnabled: true,
    );

RelativeLinkRow _link(
  String id, {
  String direction = LinkDirection.outgoing,
  String profileKind = 'self',
  String? counterpart,
}) =>
    RelativeLinkRow(
      id: id,
      direction: direction,
      profileId: 'profile-$id',
      role: 'viewer',
      counterpartName: counterpart,
      active: true,
      notifyMissed: true,
      createdAt: DateTime.utc(2026, 10, 10).microsecondsSinceEpoch,
      profileName: 'Grace Longname Profile',
      profileKind: profileKind,
    );

final _own = ProfileAccess(
  profile: _profile('self-1', 'self', 'Test User'),
  role: 'owner',
);
final _ward = ProfileAccess(
  profile: _profile('ward-1', 'managed', 'Pat Ward With A Long Name'),
  role: 'owner',
);
final _archive = ProfileAccess(
  profile: _profile('ward-2', 'managed', 'Sam Archive'),
  role: 'guardian',
  archived: true,
  archivePurgeAfter: DateTime.utc(2026, 12, 1),
);
final _foreign = ProfileAccess(
  profile: _profile('foreign-1', 'self', 'Grace Foreign'),
  role: 'viewer',
  ownerLastSeenAt: DateTime.utc(2026, 11, 1, 9),
);

Widget _scope(Widget child) {
  final everyone = [_own, _ward, _archive, _foreign];
  final newcomer = _link('new', counterpart: 'Alex Relative Longname');
  final overview = FamilyOverview(
    seeMe: [
      newcomer,
      _link('out-managed', profileKind: 'managed', counterpart: null),
    ],
    iSee: [
      _link('in-1', direction: LinkDirection.incoming, counterpart: 'Grace'),
    ],
    wards: [_ward, _archive],
  );
  return ProviderScope(
    overrides: [
      familyOverviewProvider.overrideWithValue(AsyncData(overview)),
      newRelativesProvider.overrideWithValue([newcomer]),
      selfProfileProvider.overrideWith(
        (ref) => Stream.value(_own.profile),
      ),
      accountFeaturesProvider.overrideWith(
        (ref) async => const AccountFeatures(),
      ),
      accessibleProfilesProvider.overrideWith((ref) => Stream.value(everyone)),
      accessScopesProvider.overrideWith((ref) => Stream.value(const [])),
      pushStatusProvider.overrideWith(_FixedPush.new),
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

/// A list builds only what is near the viewport: make the screen tall.
Future<void> _buildAll(WidgetTester tester, UiMatrixCase cell) async {
  tester.view.physicalSize = Size(cell.size.width, 20000);
  await tester.pump();
}

UiMatrixCheck _expectKeys(List<Key> keys) {
  return (tester, cell) async {
    await tester.pump();
    await _buildAll(tester, cell);
    expectTouchTargetsOf(tester, cell);
    for (final key in keys) {
      expect(
        find.byKey(key),
        findsOneWidget,
        reason: '$key is missing in "${cell.label}"',
      );
    }
  };
}

void main() {
  testWidgets('Family tab in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scope(const FamilyScreen()),
      expectTouchTargets: true,
      check: _expectKeys(const [
        Key('family-list'),
        Key('new-relative-banner'),
        Key('new-relative-dismiss'),
        Key('push-unavailable-hint'),
        ValueKey('link-new'),
        ValueKey('link-out-managed'),
        ValueKey('link-in-1'),
        ValueKey('link-settings-in-1'),
        ValueKey('ward-ward-1'),
        ValueKey('ward-ward-2'),
        ValueKey('ward-edit-ward-1'),
        Key('invite-self'),
        Key('accept-invite'),
        Key('add-ward'),
      ]),
    );
  });

  testWidgets('Archive banner, switcher, notes and disclosure in the matrix',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scope(
        SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ProfileSwitcher(),
              ProfileNote(access: _foreign),
              ArchivedProfileBanner(access: _archive),
              const InviteDisclosure(role: 'viewer', forSelf: true),
            ],
          ),
        ),
      ),
      expectTouchTargets: true,
      check: _expectKeys(const [
        Key('profile-switcher'),
        ValueKey('profile-switch-self-1'),
        ValueKey('profile-switch-ward-1'),
        Key('profile-zone-note'),
        Key('profile-last-sync-note'),
        Key('archive-banner'),
        Key('archive-banner-body'),
        Key('archive-leave'),
        Key('archive-purge'),
        Key('invite-disclosure'),
      ]),
    );
  });
}
