import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/api/consents_dto.dart';
import 'package:pillpal/src/data/api/relatives_dto.dart';
import 'package:pillpal/src/features/family/family_providers.dart';
import 'package:pillpal/src/features/privacy/privacy_data_screen.dart';
import 'package:pillpal/src/features/privacy/privacy_providers.dart';
import 'package:pillpal/src/features/settings/settings_account_card.dart';

import '../support/ui_matrix.dart';

// «Приватность и данные» (board B2-SettingsData) in the whole UI matrix:
// light/dark, normal/senior, RU/EN, text scale 1 and 2, two sizes.

ConsentRecord _record(String kind, {DateTime? withdrawnAt}) => ConsentRecord(
      id: '00000000-0000-4000-8000-0000000000c2',
      kind: kind,
      version: 1,
      source: 'registration',
      acceptedAt: DateTime.utc(2026, 11, 1, 9),
      withdrawnAt: withdrawnAt,
    );

ConsentsState _state(List<ConsentRecord> records) => ConsentsState(
      current: const {'health_data': 1, 'terms': 1, 'privacy': 1},
      records: records,
      missing: const [],
    );

Widget _screen({
  required Future<ConsentsState> Function() records,
  bool export = true,
}) {
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
      consentRecordsProvider.overrideWith((ref) => records()),
      accountFeaturesProvider.overrideWith(
        (ref) async => AccountFeatures(dataExportEnabled: export),
      ),
      settingsAccountProvider.overrideWith(
        (ref) async => const UserInfo(
          id: 'user-1',
          email: 'mama.test@example.org',
          emailVerified: true,
          hasPassword: true,
          region: 'ru',
          locale: 'ru',
        ),
      ),
    ],
    child: Builder(
      builder: (context) => SizedBox(
        width: MediaQuery.sizeOf(context).width,
        height: MediaQuery.sizeOf(context).height,
        child: const PrivacyDataScreen(),
      ),
    ),
  );
}

/// Height that holds a whole screen at the largest text scale of the matrix.
const double _tallScreen = 20000;

UiMatrixCheck _expect(List<String> present, [List<String> absent = const []]) {
  return (tester, cell) async {
    // The providers answer after the first frame.
    await tester.pump();
    await tester.pump();
    tester.view.physicalSize = Size(cell.size.width, _tallScreen);
    await tester.pump();
    expectTouchTargetsOf(tester, cell);
    for (final key in present) {
      expect(
        find.byKey(Key(key)),
        findsOneWidget,
        reason: '"$key" is missing in "${cell.label}"',
      );
    }
    for (final key in absent) {
      expect(
        find.byKey(Key(key)),
        findsNothing,
        reason: '"$key" is shown in "${cell.label}"',
      );
    }
  };
}

void main() {
  testWidgets('Everything given, a contribution to withdraw, the export',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        records: () async => _state([
          _record('health_data'),
          _record('terms'),
          _record('privacy'),
          _record('catalog_contribution'),
        ]),
      ),
      expectTouchTargets: true,
      check: _expect([
        'privacy-health',
        'privacy-health-withdraw',
        'privacy-terms',
        'privacy-policy',
        'privacy-contribution',
        'privacy-contribution-withdraw',
        'privacy-export',
      ]),
    );
  });

  testWidgets('Health data withdrawn, nothing else, no export', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        records: () async => _state([
          _record('health_data', withdrawnAt: DateTime.utc(2026, 11, 2)),
        ]),
        export: false,
      ),
      expectTouchTargets: true,
      check: _expect(
        ['privacy-health', 'privacy-terms', 'privacy-policy'],
        [
          'privacy-health-withdraw',
          'privacy-contribution',
          'privacy-export',
        ],
      ),
    );
  });

  testWidgets('The consents could not be loaded', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        records: () async =>
            throw const ApiException(ApiException.networkError, 0),
      ),
      expectTouchTargets: true,
      check: _expect(
        ['privacy-load-failed', 'privacy-retry', 'privacy-export'],
        ['privacy-health'],
      ),
    );
  });

  testWidgets('the screen is readable at x2.0 on 320 px', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        records: () async => _state([
          _record('health_data'),
          _record('terms'),
          _record('privacy'),
          _record('catalog_contribution'),
        ]),
      ),
      scales: const [2.0],
      sizes: const [Size(320, 568)],
      check: (tester, cell) async {
        await tester.pump();
        await tester.pump();
        tester.view.physicalSize = Size(cell.size.width, _tallScreen / 5);
        await tester.pump();
        await expectContrastOf(tester, cell);
      },
    );
  });
}
