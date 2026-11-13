import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/features/family/family_overview.dart';
import 'package:pillpal/src/features/family/family_providers.dart';
import 'package:pillpal/src/routing/routes.dart';

import 'features/catalog_ui_env.dart';
import 'helpers.dart';
import 'support/consent_server.dart';
import 'support/family_tab_fixtures.dart';
import 'support/narrow_layout.dart';

// Every main screen on the Galaxy Z Fold cover and inner screens, at text
// x1.0, x1.3 and x2.0, RU and EN, normal and senior, in the app's real
// fonts: no layout overflow and no text squeezed to a few letters per line
// (docs/design.md "Narrow screens and large text"). With NARROW_SHOTS_DIR
// set it writes screenshots and findings.txt there (never committed).

/// Ids of the seeded data a screen opens.
typedef _Ids = ({String medication});

/// One screen: how to prepare the app and how to get there.
class _Screen {
  const _Screen(
    this.name,
    this.open, {
    this.signedIn = true,
    this.overrides = const [],
  });

  final String name;
  final Future<void> Function(WidgetTester, ProviderContainer, _Ids) open;
  final bool signedIn;
  final List<Override> overrides;
}

Future<void> _go(WidgetTester tester, ProviderContainer c, String path) async {
  goRoute(c, path);
  await settleNarrow(tester);
}

/// Synthetic medications with long Russian names, two with schedules.
Future<_Ids> _seed(TestHarness harness, ProviderContainer container) async {
  await harness.seedSelfProfile();
  final first = await harness.seedMedication(
    container,
    name: 'Аторвастатин-Тева Синтетический',
    strength: '20 мг',
    stockCount: '4',
    stockUnit: 'tablet',
  );
  await harness.seedSchedule(
    container,
    first,
    testRule(times: ['08:00', '13:00', '20:00']),
  );
  final second = await harness.seedMedication(
    container,
    name: 'Метформин пролонгированного действия',
    strength: '1000 мг',
  );
  await harness.seedSchedule(container, second, testRule(times: ['09:30']));
  await harness.seedMedication(container,
      name: 'Витамин D3', privacy: 'hidden');
  return (medication: first);
}

final FamilyOverview _family = FamilyOverview(
  seeMe: [
    familyLink('new', counterpart: 'Александра Константиновна'),
    familyLink('out-managed', profileKind: 'managed'),
  ],
  iSee: [
    familyLink(
      'in-1',
      direction: LinkDirection.incoming,
      counterpart: 'Валентина Сергеевна',
    ),
  ],
  wards: [familyWard],
);

final List<_Screen> _screens = [
  _Screen('welcome', (t, c, _) async {}, signedIn: false),
  _Screen(
    'login',
    (t, c, _) => _go(t, c, AppRoutes.login),
    signedIn: false,
  ),
  _Screen(
    'register',
    (t, c, _) => _go(t, c, AppRoutes.register),
    signedIn: false,
  ),
  _Screen(
    'forgot-password',
    (t, c, _) => _go(t, c, AppRoutes.forgotPassword),
    signedIn: false,
  ),
  _Screen('today', (t, c, _) => _go(t, c, AppRoutes.today)),
  _Screen('medications', (t, c, _) => _go(t, c, AppRoutes.medications)),
  _Screen('medication-new', (t, c, _) => _go(t, c, AppRoutes.newMedication)),
  _Screen(
    'medication-edit',
    (t, c, ids) => _go(t, c, AppRoutes.medication(ids.medication)),
  ),
  _Screen(
    'schedule-new',
    (t, c, ids) => _go(t, c, AppRoutes.newSchedule(ids.medication)),
  ),
  _Screen(
    'family',
    (t, c, _) => _go(t, c, AppRoutes.family),
    overrides: [
      familyOverviewProvider.overrideWithValue(AsyncData(_family)),
    ],
  ),
  _Screen('history', (t, c, _) => _go(t, c, AppRoutes.history)),
  _Screen('report-sheet', (t, c, _) async {
    await _go(t, c, AppRoutes.history);
    await t.tap(find.byKey(const Key('history-pdf')));
    await settleNarrow(t);
  }),
  _Screen('reports', (t, c, _) => _go(t, c, AppRoutes.reports)),
  _Screen('settings', (t, c, _) => _go(t, c, AppRoutes.settings)),
  _Screen(
    'change-password',
    (t, c, _) => _go(t, c, AppRoutes.changePassword),
  ),
  _Screen('privacy-data', (t, c, _) => _go(t, c, AppRoutes.privacyData)),
  _Screen('export', (t, c, _) => _go(t, c, AppRoutes.dataExport)),
];

/// Writes screenshots of RU in normal mode at every size and scale, and of
/// every mode on the current cover screen at x1.0.
bool _shoot(NarrowCell cell) =>
    (cell.locale.languageCode == 'ru' && !cell.senior) ||
    (cell.size.width == 344 && cell.scale == 1.0);

Future<void> _runMatrix(
  WidgetTester tester,
  String name,
  ProviderContainer container,
) async {
  final findings = NarrowFindings();
  for (final cell in narrowCells()) {
    await applyNarrowCell(tester, container, cell);
    await checkNarrowScreen(
      tester,
      name,
      cell,
      findings,
      shoot: _shoot(cell),
    );
  }
  await writeNarrowFindings(tester, name, findings);
  expect(
    findings.items,
    isEmpty,
    reason: '${findings.items.length} problems on $name:\n'
        '${findings.items.take(80).join('\n')}',
  );
}

const Timeout _timeout = Timeout(Duration(minutes: 15));

void main() {
  setUpAll(loadAppFonts);

  for (final screen in _screens) {
    testWidgets('narrow: ${screen.name}', (tester) async {
      final harness = TestHarness(signedIn: screen.signedIn);
      final container = createContainer(harness, overrides: screen.overrides);
      final ids =
          screen.signedIn ? await _seed(harness, container) : (medication: '');
      await pumpNarrowApp(tester, container);
      await screen.open(tester, container, ids);
      await _runMatrix(tester, screen.name, container);
    }, timeout: _timeout);
  }

  testWidgets('narrow: consent-gate', (tester) async {
    const kinds = ['health_data', 'terms', 'privacy'];
    final server = FakeConsentServer(missing: kinds);
    final harness = TestHarness(handler: server.handle);
    final container = createContainer(harness);
    final store = container.read(syncStateStoreProvider);
    await store.bindAccount('user-1', 'ru');
    await store.saveConsentMissing('user-1', kinds);
    await pumpNarrowApp(tester, container);
    await _runMatrix(tester, 'consent-gate', container);
  }, timeout: _timeout);

  testWidgets('narrow: scan-sheet', (tester) async {
    final env = CatalogUiEnv();
    final container = createContainer(env.harness, overrides: env.overrides);
    await env.harness.seedSelfProfile();
    await pumpNarrowApp(tester, container);
    await _go(tester, container, '${AppRoutes.newMedication}?scan=1');
    await _runMatrix(tester, 'scan-sheet', container);
  }, timeout: _timeout);
}
