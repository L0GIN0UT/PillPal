import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/features/catalog/scanner_adapter.dart';
import 'package:pillpal/src/features/family/family_overview.dart';
import 'package:pillpal/src/features/family/family_providers.dart';
import 'package:pillpal/src/features/family/invite_scan_sheet.dart';
import 'package:pillpal/src/links/link_providers.dart';
import 'package:pillpal/src/routing/routes.dart';
import 'package:pillpal/src/theme/sizes.dart';

import 'family/family_fixtures.dart'
    show jsonResponse, seedForeignMedication, seedProfile;
import 'family/invite_server.dart';
import 'features/catalog_ui_env.dart';
import 'features/fake_scanner.dart';
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

/// «Близкие» with a note, a person related both ways, someone who sees a
/// managed profile and a ward.
final FamilyOverview _family = buildFamilyOverview(
  links: [
    familyLink('new', counterpart: 'Александра Константиновна'),
    familyLink('out-managed', profileKind: 'managed', role: 'guardian'),
    familyLink(
      'in-1',
      direction: LinkDirection.incoming,
      counterpart: 'Валентина Сергеевна',
      role: 'editor',
    ),
    familyLink(
      'out-1',
      counterpart: 'Валентина Сергеевна',
      counterpartProfileId: 'profile-in-1',
      role: 'editor',
    ),
  ],
  profiles: [familyWard],
  notes: const {
    'person-new': 'Двоюродная сестра',
    'profile-in-1': 'Бабушка',
  },
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
  _Screen(
    'relative-card',
    (t, c, _) => _go(t, c, AppRoutes.relative('profile-in-1')),
    overrides: [
      familyOverviewProvider.overrideWithValue(AsyncData(_family)),
    ],
  ),
  _Screen(
    'relative-card-managed',
    (t, c, _) => _go(t, c, AppRoutes.relative('ward-1')),
    overrides: [
      familyOverviewProvider.overrideWithValue(AsyncData(_family)),
    ],
  ),
  _Screen('add-relative', (t, c, _) => _go(t, c, AppRoutes.addRelative)),
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
  _Screen('own-name', (t, c, _) => _go(t, c, AppRoutes.ownName)),
  _Screen('privacy-data', (t, c, _) => _go(t, c, AppRoutes.privacyData)),
  _Screen('export', (t, c, _) => _go(t, c, AppRoutes.dataExport)),
];

/// Writes screenshots of RU in normal mode at every size and scale, and of
/// every mode on the current cover screen at x1.0.
bool _shoot(NarrowCell cell) =>
    (cell.locale.languageCode == 'ru' && !cell.senior) ||
    (cell.size.width == 344 && cell.scale == 1.0);

/// Where squeezed text fails the test: the default text everywhere, and on
/// the current cover and the inner screens text x1.3 too (system x1.3, or
/// senior mode). Larger text on the narrowest cover is reported only: a
/// single word can be wider than the column there whatever the layout.
bool _strict(NarrowCell cell) {
  final scale = cell.scale * (cell.senior ? PillPalSizes.seniorTextScale : 1);
  if (cell.size.width >= narrowInnerWidth) {
    return true;
  }
  return scale <= 1 ||
      (cell.size.width >= narrowCoverWidth && scale <= _strictCoverScale);
}

/// The largest text (system times senior) that must not squeeze on the
/// current cover screen.
const double _strictCoverScale = 1.3;

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
      strict: _strict(cell),
    );
  }
  await writeNarrowFindings(tester, name, findings);
  expect(
    findings.failures,
    isEmpty,
    reason: '${findings.failures.length} problems on $name:\n'
        '${findings.failures.take(80).join('\n')}',
  );
}

const Timeout _timeout = Timeout(Duration(minutes: 15));

/// Heavy: locally `flutter test -x narrow` skips them; CI runs them.
const List<String> _tags = ['narrow'];

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
    }, timeout: _timeout, tags: _tags);
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
  }, timeout: _timeout, tags: _tags);

  testWidgets('narrow: today-viewer', (tester) async {
    // A relative's day as a viewer: pills instead of checks (canMark false).
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final profile = await seedProfile(harness, name: 'Валентина Сергеевна');
    await seedForeignMedication(
      harness,
      container,
      profile,
      name: 'Метформин пролонгированного действия',
      strength: '1000 мг',
      times: ['08:00', '13:00', '20:00', '22:00'],
    );
    await pumpNarrowApp(tester, container);
    openRoute(container, AppRoutes.profileToday(profile));
    await settleNarrow(tester);
    await _runMatrix(tester, 'today-viewer', container);
  }, timeout: _timeout, tags: _tags);

  testWidgets('narrow: scan-sheet', (tester) async {
    final env = CatalogUiEnv();
    final container = createContainer(env.harness, overrides: env.overrides);
    await env.harness.seedSelfProfile();
    await pumpNarrowApp(tester, container);
    await _go(tester, container, '${AppRoutes.newMedication}?scan=1');
    await _runMatrix(tester, 'scan-sheet', container);
  }, timeout: _timeout, tags: _tags);

  testWidgets('narrow: add-relative-code', (tester) async {
    // The QR code with its countdown and the helper box: the code scales
    // down on the narrowest cover instead of overflowing.
    final harness = TestHarness(handler: FakeInviteServer().handle);
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    await pumpNarrowApp(tester, container);
    await _go(tester, container, AppRoutes.addRelative);
    final show = find.byKey(const Key('add-relative-show-code'));
    await tester.ensureVisible(show);
    await tester.tap(show);
    await settleNarrow(tester);
    expect(find.byKey(const Key('invite-qr')), findsOneWidget);
    await _runMatrix(tester, 'add-relative-code', container);
  }, timeout: _timeout, tags: _tags);

  for (final failure in ScannerFailure.values) {
    testWidgets('narrow: invite-scan-sheet-${failure.name}', (tester) async {
      // The scanner without a camera: its notice and «Вставить ссылку».
      final harness = TestHarness();
      final container = createContainer(
        harness,
        overrides: [
          inviteScannerFactoryProvider.overrideWithValue(
            () => _FailedScanner(failure),
          ),
        ],
      );
      await harness.seedSelfProfile();
      await pumpNarrowApp(tester, container);
      await _go(tester, container, AppRoutes.addRelative);
      // Below the disclosure: the list builds it only once scrolled to.
      final scan = find.byKey(const Key('add-relative-scan'));
      await tester.scrollUntilVisible(
        scan,
        200,
        scrollable: find.descendant(
          of: find.byKey(const Key('add-relative-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(scan);
      await settleNarrow(tester);
      expect(
        find.byKey(
          Key(
            failure == ScannerFailure.permissionDenied
                ? 'invite-scan-notice-permission'
                : 'invite-scan-notice-unavailable',
          ),
        ),
        findsOneWidget,
      );
      await _runMatrix(tester, 'invite-scan-sheet-${failure.name}', container);
    }, timeout: _timeout, tags: _tags);
  }

  testWidgets('narrow: accept-preview-email', (tester) async {
    // Who shares, with the masked e-mail on its own line, and the caution.
    final harness = TestHarness(
      handler: (request) async => request.url.path == '/v1/invites/preview'
          ? jsonResponse({
              'inviter_display_name': 'Александра Константиновна',
              'inviter_email_masked': 'a***@a***.family',
              'profile_display_name': 'Александра Константиновна',
              'profile_kind': 'self',
              'role': 'editor',
              'expires_at': '2026-10-16T06:15:00Z',
            })
          : http.Response('', 503),
    );
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    await pumpNarrowApp(tester, container);
    container.read(inviteIntakeProvider.notifier).offer(inviteUrl);
    await _go(tester, container, AppRoutes.acceptInvite);
    expect(find.byKey(const Key('invite-preview-email')), findsOneWidget);
    await _runMatrix(tester, 'accept-preview-email', container);
  }, timeout: _timeout, tags: _tags);

  testWidgets('narrow: search-sheet', (tester) async {
    // Results of mixed forms with the keyboard up: the sheet keeps to the
    // space above it and nothing overflows.
    final env = CatalogUiEnv()
      ..results = [
        searchResultJson(
          id: 'ru-1',
          name: 'Аторвастатин-Тева Синтетический',
          form: 'ТАБЛЕТКИ, ПОКРЫТЫЕ ПЛЕНОЧНОЙ ОБОЛОЧКОЙ',
        ),
        searchResultJson(
          id: 'ru-2',
          name: 'Аторвастатин Синтетический',
          form: 'КАПСУЛЫ',
        ),
      ];
    final container = createContainer(env.harness, overrides: env.overrides);
    await env.harness.seedSelfProfile();
    await pumpNarrowApp(tester, container);
    await _go(tester, container, AppRoutes.newMedication);
    await tester.ensureVisible(find.byKey(const Key('med-catalog')));
    await settleNarrow(tester);
    await tester.tap(find.byKey(const Key('med-catalog')));
    await settleNarrow(tester);
    await tester.enterText(
      find.byKey(const Key('catalog-search-text')),
      'аторва',
    );
    await tester.tap(find.byKey(const Key('catalog-search-go')));
    await settleNarrow(tester);
    tester.view.viewInsets = FakeViewPadding(
      bottom: _keyboard * tester.view.devicePixelRatio,
    );
    await _runMatrix(tester, 'search-sheet', container);
  }, timeout: _timeout, tags: _tags);
}

/// A camera that reports [failure] as the invite scanner listens.
class _FailedScanner extends FakeScannerAdapter {
  _FailedScanner(this.failure);

  final ScannerFailure failure;

  @override
  Stream<ScannerFailure> get failures => Stream.value(failure);
}

/// Height of the keyboard in the search-sheet check (logical pixels).
const double _keyboard = 260;
