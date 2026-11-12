import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/api/relatives_dto.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/access_repository.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/features/family/accept_invite_views.dart';
import 'package:pillpal/src/features/family/invite_create_screen.dart';
import 'package:pillpal/src/features/family/managed_profile_screen.dart';
import 'package:pillpal/src/features/family/profile_context.dart';
import 'package:pillpal/src/features/family/relative_privacy_section.dart';

import '../support/ui_matrix.dart';

// R6b at the narrowest setting, B2-README section 9: 320 px, RU, text x2.0,
// in every theme and in senior mode. The pinned buttons stay on screen (also
// with the keyboard up), the fields stay reachable, the privacy control falls
// back to a radio list, and the text is readable (7:1 in senior mode).

const Size _narrow = Size(320, 568);
const double _keyboard = 250;

/// Tall enough for the longest screen at x2.6 text (RU, senior, x2.0), so
/// nothing is scrolled out of the view or built beneath a pinned button.
const double _wholeScreen = 12000;

ProfileRow _profile(String id, String kind) => ProfileRow(
      id: id,
      kind: kind,
      displayName: 'Pat Ward With A Long Name',
      timezone: 'Asia/Tokyo',
      clientUpdatedAt: 1,
      updatedByDevice: 'test-device',
      missedAlertMinutes: 30,
      missedAlertsEnabled: true,
    );

class _FakeAccessRepository implements AccessRepository {
  @override
  Future<bool> remindsOnDevice(String profileId) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MedicationRow _medication(String id, String name) => MedicationRow(
      id: id,
      profileId: 'ward-1',
      name: name,
      tzMode: 'local',
      privacy: 'shared',
      redacted: false,
      gtinLinkShared: false,
      clientUpdatedAt: 1,
      updatedByDevice: 'test-device',
    );

Widget _scope(Widget child) {
  final ward = ProfileAccess(
    profile: _profile('ward-1', 'managed'),
    role: 'owner',
  );
  return ProviderScope(
    overrides: [
      deviceTimeZoneProvider.overrideWithValue('Europe/Moscow'),
      profileAccessProvider('ward-1').overrideWith((ref) => Stream.value(ward)),
      accessRepositoryProvider.overrideWithValue(_FakeAccessRepository()),
      relativePrivacyMedicationsProvider('ward-1').overrideWith(
        (ref) => Stream.value([
          _medication('m-1', 'Enalapril With A Long Name'),
          _medication('m-2', 'Omega'),
        ]),
      ),
    ],
    child: child,
  );
}

/// The whole screen on one tall surface, then the contrast guideline: the
/// senior guideline also reads text scrolled out of view.
Future<void> _contrast(WidgetTester tester, UiMatrixCase cell) async {
  tester.view.physicalSize = Size(cell.size.width, _wholeScreen);
  await tester.pump();
  await expectContrastOf(tester, cell);
}

void _expectOnScreen(WidgetTester tester, Finder finder, double height) {
  final rect = tester.getRect(finder);
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.bottom, lessThanOrEqualTo(height));
}

Future<void> _pumpWith(
  WidgetTester tester,
  Widget Function(BuildContext) builder,
  UiMatrixCheck check,
) {
  return pumpUiMatrix(
    tester,
    builder,
    scales: const [2.0],
    sizes: const [_narrow],
    expectTouchTargets: true,
    check: check,
  );
}

void main() {
  testWidgets('pinned create stays on screen, also with the keyboard',
      (tester) async {
    await _pumpWith(
      tester,
      (context) => _scope(const InviteCreateScreen(profileId: 'ward-1')),
      (tester, cell) async {
        await tester.pump();
        final button = find.byKey(const Key('invite-create'));
        _expectOnScreen(tester, button, _narrow.height);
        tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
        await tester.pump();
        _expectOnScreen(tester, button, _narrow.height - _keyboard);
        tester.view.resetViewInsets();
        await _contrast(tester, cell);
      },
    );
  });

  testWidgets('pinned save stays on screen and fields are reachable',
      (tester) async {
    await _pumpWith(
      tester,
      (context) => _scope(const ManagedProfileScreen(profileId: 'ward-1')),
      (tester, cell) async {
        await tester.pump();
        final save = find.byKey(const Key('ward-save'));
        _expectOnScreen(tester, save, _narrow.height);
        tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
        await tester.pump();
        _expectOnScreen(tester, save, _narrow.height - _keyboard);
        // The field a keyboard would cover scrolls into the space left.
        await tester.ensureVisible(find.byKey(const Key('ward-zone')));
        await tester.pump();
        _expectOnScreen(
          tester,
          find.byKey(const Key('ward-zone')),
          _narrow.height - _keyboard,
        );
        tester.view.resetViewInsets();
        await _contrast(tester, cell);
      },
    );
  });

  testWidgets('privacy control falls back to a radio list in RU',
      (tester) async {
    await _pumpWith(
      tester,
      (context) => _scope(
        const SingleChildScrollView(
          child: RelativePrivacySection(profileId: 'ward-1', name: 'Alex'),
        ),
      ),
      (tester, cell) async {
        await tester.pump();
        if (cell.locale.languageCode == 'ru') {
          expect(find.byKey(const Key('segmented-radio-list')), findsWidgets);
        }
        expect(
          find.byKey(const ValueKey('relative-privacy-m-1-hidden')),
          findsOneWidget,
        );
        await _contrast(tester, cell);
      },
    );
  });

  testWidgets('accept buttons are stacked, whole and readable', (tester) async {
    final preview = InvitePreview(
      inviterDisplayName: 'Grace Owner With A Long Name',
      profileDisplayName: 'Pat Ward',
      profileKind: 'self',
      role: 'editor',
      expiresAt: DateTime.utc(2026, 10, 23, 8),
    );
    await _pumpWith(
      tester,
      (context) => _scope(
        SingleChildScrollView(
          child: InvitePreviewView(
            preview: preview,
            busy: false,
            errorCode: null,
            onAccept: () {},
            onDecline: () {},
          ),
        ),
      ),
      (tester, cell) async {
        tester.view.physicalSize = Size(cell.size.width, _wholeScreen);
        await tester.pump();
        final accept = tester.getRect(find.byKey(const Key('accept-confirm')));
        final decline = tester.getRect(find.byKey(const Key('accept-decline')));
        expect(decline.top, greaterThanOrEqualTo(accept.bottom));
        expect(accept.width, decline.width);
        expect(find.byKey(const Key('invite-preview-sees')), findsOneWidget);
        await expectContrastOf(tester, cell);
      },
    );
  });
}
