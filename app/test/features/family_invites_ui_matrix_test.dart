import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/api/relatives_dto.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/features/common/banner_tone.dart';
import 'package:pillpal/src/features/common/pillpal_banner.dart';
import 'package:pillpal/src/features/family/accept_invite_screen.dart';
import 'package:pillpal/src/features/family/accept_invite_views.dart';
import 'package:pillpal/src/features/family/family_overview.dart';
import 'package:pillpal/src/features/family/family_providers.dart';
import 'package:pillpal/src/features/family/invite_create_screen.dart';
import 'package:pillpal/src/features/family/invite_disclosure.dart';
import 'package:pillpal/src/features/family/managed_profile_screen.dart';
import 'package:pillpal/src/features/family/profile_context.dart';
import 'package:pillpal/src/features/family/relative_card_screen.dart';
import 'package:pillpal/src/features/family/relative_privacy_section.dart';
import 'package:pillpal/src/links/invite_link.dart';
import 'package:pillpal/src/links/link_providers.dart';

import '../support/family_matrix.dart';
import '../support/ui_matrix.dart';

// The invite and detail screens of the Family feature in the whole UI matrix
// (docs/ui-pass-plan.md, UI-6b). Data is synthetic; providers are fixed here.
// «Добавить близкого», the QR panel and the scanner are in
// family_add_relative_ui_matrix_test.dart.

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
      counterpartProfileId:
          direction == LinkDirection.incoming ? 'profile-$id' : 'person-$id',
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

class _HeldProblem extends InviteIntakeNotifier {
  @override
  InviteIntake? build() => const InviteIntake(
        InviteLinkResult.rejected(InviteLinkProblem.malformed),
      );
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
        (context) =>
            familyMatrixScope(InviteCreateScreen(profileId: entry.key)),
        expectTouchTargets: true,
        check: (tester, cell) => expectMatrixKeys(tester, cell, [
          const ValueKey('invite-role-viewer'),
          const ValueKey('invite-role-editor'),
          ...entry.value,
        ]),
      );
    }
  });

  testWidgets('Disclosure of every role in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => matrixScrolling(
        const Column(
          children: [
            InviteDisclosure(role: 'viewer', forSelf: true),
            InviteDisclosure(role: 'guardian', forSelf: false),
          ],
        ),
      ),
      check: (tester, cell) async {
        expect(find.byKey(const Key('invite-disclosure')), findsNWidgets(2));
        await expectMatrixContrast(tester, cell);
      },
    );
  });

  testWidgets('Accept invite paste form with a problem in the matrix',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => familyMatrixScope(
        const AcceptInviteScreen(),
        [inviteIntakeProvider.overrideWith(_HeldProblem.new)],
      ),
      expectTouchTargets: true,
      check: (tester, cell) => expectMatrixKeys(tester, cell, const [
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
        inviterEmailMasked: 'g***@g***.family',
        profileDisplayName: 'Pat Ward',
        profileKind: role == 'guardian' ? 'managed' : 'self',
        role: role,
        expiresAt: DateTime.utc(2026, 10, 23, 8),
      );
      await pumpUiMatrix(
        tester,
        (context) => matrixScrolling(
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
          await expectMatrixKeys(tester, cell, [
            const Key('invite-preview-title'),
            const Key('invite-preview-email'),
            const Key('invite-preview-caution'),
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
      (context) => matrixScrolling(InviteAcceptedView(grant: grant)),
      expectTouchTargets: true,
      check: (tester, cell) => expectMatrixKeys(tester, cell, const [
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
      (context) => familyMatrixScope(const ManagedProfileScreen()),
      expectTouchTargets: true,
      check: (tester, cell) => expectMatrixKeys(tester, cell, const [
        Key('ward-name'),
        Key('ward-zone'),
        Key('ward-alerts'),
        Key('ward-save'),
      ]),
    );
    await pumpUiMatrix(
      tester,
      (context) =>
          familyMatrixScope(const ManagedProfileScreen(profileId: 'ward-1')),
      expectTouchTargets: true,
      check: (tester, cell) => expectMatrixKeys(tester, cell, const [
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
          Key('relative-note-field'),
          Key('relative-note-save'),
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
        const [
          Key('relative-note-field'),
          Key('relative-note-save'),
          Key('notify-missed'),
          Key('detail-open'),
          Key('detail-leave'),
        ],
      ),
    };
    for (final entry in scenarios.entries) {
      final link = entry.value.$1;
      await pumpUiMatrix(
        tester,
        (context) => familyMatrixScope(
          RelativeCardScreen(linkId: entry.key),
          [
            grantLinksProvider.overrideWith((ref) => Stream.value([link])),
            familyOverviewProvider.overrideWithValue(
              AsyncData(
                buildFamilyOverview(
                  links: [link],
                  profiles: const [],
                  notes: const {'person-out-1': 'Сын'},
                ),
              ),
            ),
            profileAccessProvider(link.profileId).overrideWith(
              (ref) => Stream.value(
                ProfileAccess(
                  profile: matrixProfile(link.profileId, link.profileKind, 'P'),
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
        check: (tester, cell) => expectMatrixKeys(tester, cell, entry.value.$2),
      );
    }
  });
}
