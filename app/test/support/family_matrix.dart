import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/access_repository.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/features/family/profile_context.dart';

import 'ui_matrix.dart';

// Shared fixtures of the Family UI matrix tests (invites, «Добавить
// близкого», details). Data is synthetic; providers are fixed here.

/// A profile row of the matrix.
ProfileRow matrixProfile(String id, String kind, String name) => ProfileRow(
      id: id,
      kind: kind,
      displayName: name,
      timezone: 'Asia/Tokyo',
      clientUpdatedAt: 1,
      updatedByDevice: 'test-device',
      missedAlertMinutes: 30,
      missedAlertsEnabled: true,
    );

/// The own `self` profile.
final ProfileAccess matrixOwn = ProfileAccess(
  profile: matrixProfile('self-1', 'self', 'Test User'),
  role: 'owner',
);

/// A managed profile the account owns.
final ProfileAccess matrixWard = ProfileAccess(
  profile: matrixProfile('ward-1', 'managed', 'Pat Ward With A Long Name'),
  role: 'owner',
);

/// Only what [ManagedProfileScreen]-like screens read from the repository.
class MatrixAccessRepository implements AccessRepository {
  @override
  Future<bool> remindsOnDevice(String profileId) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The providers the Family screens read, with [extra] on top.
Widget familyMatrixScope(Widget child, [List<Override> extra = const []]) {
  return ProviderScope(
    overrides: [
      deviceTimeZoneProvider.overrideWithValue('Europe/Moscow'),
      profileAccessProvider('self-1').overrideWith(
        (ref) => Stream.value(matrixOwn),
      ),
      profileAccessProvider('ward-1').overrideWith(
        (ref) => Stream.value(matrixWard),
      ),
      accessRepositoryProvider.overrideWithValue(MatrixAccessRepository()),
      ...extra,
    ],
    child: child,
  );
}

/// A view that is not a screen, scrolling with the form padding.
Widget matrixScrolling(Widget child) => SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: child,
    );

/// Tall enough to show a whole screen at the one cell where contrast is read.
const double _contrastHeight = 4000;

/// Contrast of the text of the whole screen at the cell `expectContrast`
/// uses: the guideline of senior mode also reads text that is scrolled out of
/// the view, which would sit outside the picture, so the screen is made tall
/// first (as `day_details_test` does).
Future<void> expectMatrixContrast(
  WidgetTester tester,
  UiMatrixCase cell,
) async {
  if (cell.scale != uiContrastScale || cell.size != uiContrastSize) {
    return;
  }
  tester.view.physicalSize = Size(cell.size.width, _contrastHeight);
  await tester.pump();
  await expectContrastOf(tester, cell);
}

/// Makes the screen tall (a ListView builds only what is near the viewport),
/// expects exactly one widget for each key and reads the contrast.
Future<void> expectMatrixKeys(
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
  await expectMatrixContrast(tester, cell);
}
