import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/relatives_dto.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/access_repository.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/features/common/banner_tone.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/features/common/pillpal_banner.dart';
import 'package:pillpal/src/features/family/accept_invite_screen.dart';
import 'package:pillpal/src/features/family/accept_invite_views.dart';
import 'package:pillpal/src/features/family/family_providers.dart';
import 'package:pillpal/src/features/family/invite_create_screen.dart';
import 'package:pillpal/src/features/family/invite_disclosure.dart';
import 'package:pillpal/src/features/family/invite_share_view.dart';
import 'package:pillpal/src/features/family/managed_profile_screen.dart';
import 'package:pillpal/src/features/family/profile_context.dart';
import 'package:pillpal/src/features/family/relative_detail_screen.dart';
import 'package:pillpal/src/features/family/relative_privacy_section.dart';
import 'package:pillpal/src/links/invite_link.dart';
import 'package:pillpal/src/links/link_providers.dart';

import '../support/ui_matrix.dart';

// The invite and detail screens of the Family feature in the whole UI matrix
// (docs/ui-pass-plan.md, UI-6b). Data is synthetic; providers are fixed here.

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

final _own = ProfileAccess(
  profile: _profile('self-1', 'self', 'Test User'),
  role: 'owner',
);
final _ward = ProfileAccess(
  profile: _profile('ward-1', 'managed', 'Pat Ward With A Long Name'),
  role: 'owner',
);

RelativeLinkRow _link(
  String id, {
  String direction = LinkDirection.outgoing,
  String role = 'viewer',
  bool active = true,
  String profileKind = 'self',
}) =>
    RelativeLinkRow(
      id: id,
      direction: direction,
      profileId: 'profile-$id',
      role: role,
      counterpartName: 'Alex Relative With A Long Name',
      active: active,
      notifyMissed: true,
      createdAt: DateTime.utc(2026, 10, 10).microsecondsSinceEpoch,
      profileName: 'Grace Longname Profile',
      profileKind: profileKind,
    );

MedicationRow _medication(String id, String name, String privacy) =>
    MedicationRow(
      id: id,
      profileId: 'profile-out-1',
      name: name,
      tzMode: 'local',
      privacy: privacy,
      redacted: false,
      gtinLinkShared: false,
      clientUpdatedAt: 1,
      updatedByDevice: 'test-device',
    );

/// Only what [ManagedProfileScreen] reads from the repository.
class _FakeAccessRepository implements AccessRepository {
  @override
  Future<bool> remindsOnDevice(String profileId) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HeldProblem extends InviteIntakeNotifier {
  @override
  InviteIntake? build() => const InviteIntake(
        InviteLinkResult.rejected(InviteLinkProblem.malformed),
      );
}

Widget _scope(Widget child, [List<Override> extra = const []]) {
  return ProviderScope(
    overrides: [
      deviceTimeZoneProvider.overrideWithValue('Europe/Moscow'),
      profileAccessProvider('self-1').overrideWith(
        (ref) => Stream.value(_own),
      ),
      profileAccessProvider('ward-1').overrideWith(
        (ref) => Stream.value(_ward),
      ),
      accessRepositoryProvider.overrideWithValue(_FakeAccessRepository()),
      ...extra,
    ],
    child: child,
  );
}

Widget _scrolling(Widget child) => SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: child,
    );

/// Tall enough to show a whole screen at the one cell where contrast is read.
const double _contrastHeight = 4000;

/// Contrast of the text of the whole screen at the cell `expectContrast`
/// uses: the guideline of senior mode also reads text that is scrolled out of
/// the view, which would sit outside the picture, so the screen is made tall
/// first (as `day_details_test` does).
Future<void> _expectContrast(WidgetTester tester, UiMatrixCase cell) async {
  if (cell.scale != uiContrastScale || cell.size != uiContrastSize) {
    return;
  }
  tester.view.physicalSize = Size(cell.size.width, _contrastHeight);
  await tester.pump();
  await expectContrastOf(tester, cell);
}

/// Makes the screen tall (a ListView builds only what is near the viewport),
/// expects exactly one widget for each key and reads the contrast.
Future<void> _expectKeys(
  WidgetTester tester,
  UiMatrixCase cell,
  List<Key> keys,
) async {
  await tester.pump();
  tester.view.physicalSize = Size(cell.size.width, 20000);
  await tester.pump();
  expectTouchTargetsOf(tester, cell);
  for (final key in keys) {
    expect(
      find.byKey(key),
      findsOneWidget,
      reason: '$key is missing in "${cell.label}"',
    );
  }
  await _expectContrast(tester, cell);
}

void main() {
  testWidgets('Invite create form (own and managed) in the matrix',
      (tester) async {
    final scenarios = <String, List<Key>>{
      'self-1': const [Key('invite-create'), Key('invite-disclosure')],
      'ward-1': const [
        Key('invite-create'),
        Key('invite-disclosure'),
        ValueKey('invite-role-guardian'),
      ],
    };
    for (final entry in scenarios.entries) {
      await pumpUiMatrix(
        tester,
        (context) => _scope(InviteCreateScreen(profileId: entry.key)),
        expectTouchTargets: true,
        check: (tester, cell) => _expectKeys(tester, cell, [
          const ValueKey('invite-role-viewer'),
          const ValueKey('invite-role-editor'),
          ...entry.value,
        ]),
      );
    }
  });

  testWidgets('Invite share view in the matrix', (tester) async {
    final invite = InviteCreated(
      id: 'invite-1',
      role: 'viewer',
      expiresAt: DateTime.utc(2026, 10, 23, 8),
      url: 'https://links-ru.pillpal.invalid/i#abcdefghijklmnopqrstuvwxyz',
    );
    await pumpUiMatrix(
      tester,
      (context) => _scope(
        _scrolling(InviteShareView(invite: invite, onDone: () {})),
      ),
      expectTouchTargets: true,
      check: (tester, cell) => _expectKeys(tester, cell, const [
        Key('invite-qr'),
        Key('invite-valid-until'),
        Key('invite-share'),
        Key('invite-done'),
      ]),
    );
  });

  testWidgets('Disclosure of every role in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scrolling(
        const Column(
          children: [
            InviteDisclosure(role: 'viewer', forSelf: true),
            InviteDisclosure(role: 'guardian', forSelf: false),
          ],
        ),
      ),
      check: (tester, cell) async {
        expect(find.byKey(const Key('invite-disclosure')), findsNWidgets(2));
        await _expectContrast(tester, cell);
      },
    );
  });

  testWidgets('Accept invite paste form with a problem in the matrix',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scope(
        const AcceptInviteScreen(),
        [inviteIntakeProvider.overrideWith(_HeldProblem.new)],
      ),
      expectTouchTargets: true,
      check: (tester, cell) => _expectKeys(tester, cell, const [
        Key('accept-link-field'),
        Key('accept-paste'),
        Key('accept-check'),
        Key('accept-problem'),
      ]),
    );
  });

  testWidgets('Invite preview and accepted views in the matrix',
      (tester) async {
    for (final role in ['viewer', 'guardian']) {
      final preview = InvitePreview(
        inviterDisplayName: 'Grace Owner With A Long Name',
        profileDisplayName: 'Pat Ward',
        profileKind: role == 'guardian' ? 'managed' : 'self',
        role: role,
        expiresAt: DateTime.utc(2026, 10, 23, 8),
      );
      await pumpUiMatrix(
        tester,
        (context) => _scrolling(
          InvitePreviewView(
            preview: preview,
            busy: false,
            errorCode: 'invite_expired',
            onAccept: () {},
            onDecline: () {},
          ),
        ),
        expectTouchTargets: true,
        check: (tester, cell) async {
          await _expectKeys(tester, cell, [
            const Key('invite-preview-title'),
            const Key('invite-preview-role'),
            const Key('accept-error'),
            const Key('accept-confirm'),
            const Key('accept-decline'),
            if (role == 'guardian') const Key('guardian-warning'),
          ]);
          final warning = find.byKey(const Key('guardian-warning'));
          if (role == 'guardian') {
            expect(
              tester.widget<PillPalBanner>(warning).tone,
              BannerTone.info,
              reason: 'the guardian warning is not a danger banner',
            );
          }
        },
      );
    }
    final grant = IncomingGrant(
      id: 'in-1',
      profileId: 'profile-1',
      profileDisplayName: 'Pat Ward With A Long Name',
      profileKind: 'managed',
      role: 'viewer',
      ownerDisplayName: 'Grace Owner',
      notifyMissed: true,
      createdAt: DateTime.utc(2026, 10, 10),
    );
    await pumpUiMatrix(
      tester,
      (context) => _scrolling(InviteAcceptedView(grant: grant)),
      expectTouchTargets: true,
      check: (tester, cell) => _expectKeys(tester, cell, const [
        Key('invite-accepted'),
        Key('accepted-open'),
        Key('accepted-done'),
      ]),
    );
  });

  testWidgets('Managed profile form (new and existing) in the matrix',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _scope(const ManagedProfileScreen()),
      expectTouchTargets: true,
      check: (tester, cell) => _expectKeys(tester, cell, const [
        Key('ward-name'),
        Key('ward-zone'),
        Key('ward-alerts'),
        Key('ward-save'),
      ]),
    );
    await pumpUiMatrix(
      tester,
      (context) => _scope(const ManagedProfileScreen(profileId: 'ward-1')),
      expectTouchTargets: true,
      check: (tester, cell) => _expectKeys(tester, cell, const [
        Key('ward-remind'),
        Key('ward-invite'),
        Key('ward-delete'),
      ]),
    );
  });

  testWidgets('Relative detail screens in the matrix', (tester) async {
    final scenarios = <String, (RelativeLinkRow, List<Key>)>{
      'out-1': (
        _link('out-1'),
        const [
          ValueKey('detail-role-viewer'),
          ValueKey('detail-role-editor'),
          Key('invite-disclosure'),
          Key('detail-save-role'),
          Key('detail-revoke'),
          Key('relative-privacy-all-note'),
          ValueKey('relative-privacy-med-1-shared'),
          ValueKey('relative-privacy-med-1-anonymous'),
          ValueKey('relative-privacy-med-1-hidden'),
          ValueKey('relative-privacy-med-2-hidden'),
        ],
      ),
      'out-2': (
        _link('out-2', role: 'guardian', active: false, profileKind: 'managed'),
        const [Key('link-inactive'), Key('detail-revoke')],
      ),
      'in-1': (
        _link('in-1', direction: LinkDirection.incoming),
        const [Key('notify-missed'), Key('detail-open'), Key('detail-leave')],
      ),
    };
    for (final entry in scenarios.entries) {
      final link = entry.value.$1;
      await pumpUiMatrix(
        tester,
        (context) => _scope(
          RelativeDetailScreen(linkId: entry.key),
          [
            grantLinksProvider.overrideWith((ref) => Stream.value([link])),
            profileAccessProvider(link.profileId).overrideWith(
              (ref) => Stream.value(
                ProfileAccess(
                  profile: _profile(link.profileId, link.profileKind, 'P'),
                  role: link.direction == LinkDirection.outgoing
                      ? 'owner'
                      : 'viewer',
                ),
              ),
            ),
            relativePrivacyMedicationsProvider(link.profileId).overrideWith(
              (ref) => Stream.value([
                _medication('med-1', 'Enalapril With A Long Name', 'shared'),
                _medication('med-2', 'Omega', 'hidden'),
              ]),
            ),
          ],
        ),
        expectTouchTargets: true,
        check: (tester, cell) => _expectKeys(tester, cell, entry.value.$2),
      );
    }
  });
}
