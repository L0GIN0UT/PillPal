import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/family/archived_profile_banner.dart';
import 'package:pillpal/src/features/family/family_screen.dart';
import 'package:pillpal/src/features/family/invite_disclosure.dart';
import 'package:pillpal/src/features/family/profile_note.dart';
import 'package:pillpal/src/features/family/profile_switcher.dart';

import '../support/family_tab_fixtures.dart';
import '../support/ui_matrix.dart';

// The Family tab and its parts in the whole UI matrix (docs/ui-pass-plan.md,
// UI-6a; «Забота» R6a): touch targets and text contrast in every cell, RU at
// x2.0 on 320 px included. Data is synthetic and the providers are fixed by
// the test (test/support/family_tab_fixtures.dart).

/// A list builds only what is near the viewport: make the screen tall.
Future<void> _buildAll(WidgetTester tester, UiMatrixCase cell) async {
  tester.view.physicalSize = Size(cell.size.width, 20000);
  await tester.pump();
}

UiMatrixCheck _expectKeys(List<Key> keys) {
  return (tester, cell) async {
    await tester.pump();
    await _buildAll(tester, cell);
    // Again after the list is built in full: `expectTouchTargets` of
    // pumpUiMatrix only sees the part near the viewport.
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
      (context) => familyScope(
        const FamilyScreen(),
        fresh: [familyLink('new', counterpart: 'Alex Relative Longname')],
        days: {
          'ward-1': familyDay(taken: 2),
          'profile-in-1': familyDay(taken: 1, missed: 2, pending: 1),
        },
      ),
      expectTouchTargets: true,
      expectContrast: true,
      check: _expectKeys(const [
        Key('family-list'),
        Key('new-relative-banner'),
        Key('new-relative-dismiss'),
        Key('push-unavailable-hint'),
        ValueKey('link-new'),
        ValueKey('link-out-managed'),
        ValueKey('link-out-paused'),
        ValueKey('link-in-1'),
        ValueKey('link-settings-in-1'),
        ValueKey('ward-ward-1'),
        ValueKey('ward-ward-2'),
        ValueKey('ward-edit-ward-1'),
        Key('day-status-ward-1'),
        Key('day-status-profile-in-1'),
        Key('day-next-profile-in-1'),
        Key('invite-self'),
        Key('accept-invite'),
        Key('add-ward'),
      ]),
    );
  });

  testWidgets('Family tab with old data in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => familyScope(
        const FamilyScreen(),
        days: {
          'ward-1': familyDay(
            taken: 1,
            pending: 1,
            staleAge: const Duration(hours: 8),
          ),
          'profile-in-1': familyDay(
            missed: 1,
            staleAge: const Duration(days: 4),
          ),
        },
      ),
      expectTouchTargets: true,
      expectContrast: true,
      check: _expectKeys(const [
        Key('day-stale-ward-1'),
        Key('day-stale-profile-in-1'),
      ]),
    );
  });

  testWidgets('Empty family in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => familyScope(
        const FamilyScreen(),
        overview: familyNobody,
        pushHint: false,
      ),
      expectTouchTargets: true,
      expectContrast: true,
      check: _expectKeys(const [
        Key('family-list'),
        Key('empty-state-disc'),
        Key('invite-self'),
        Key('add-ward'),
        Key('accept-invite'),
      ]),
    );
  });

  testWidgets('Archive banner, switcher, notes and disclosure in the matrix',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => familyScope(
        SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ProfileSwitcher(),
              ProfileNote(access: familyForeign),
              ArchivedProfileBanner(access: familyArchive),
              const InviteDisclosure(role: 'viewer', forSelf: true),
            ],
          ),
        ),
      ),
      expectTouchTargets: true,
      expectContrast: true,
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
