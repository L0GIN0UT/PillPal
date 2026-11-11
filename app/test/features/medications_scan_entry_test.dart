import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/features/family/add_medication_route.dart';
import 'package:pillpal/src/settings/app_settings.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../data/catalog_fixtures.dart';
import '../family/family_fixtures.dart';
import '../helpers.dart';
import 'catalog_ui_env.dart';
import 'fake_scanner.dart';

// The scan entry of the Medications screen (docs/ui-pass-plan.md D4, closes
// the 4.11 deferral): an extended button that opens the add form with the
// scanner already up. "+" in the app bar still opens the plain form.

const Key _scanButton = Key('medications-scan');

CatalogUiEnv _env() {
  final env = CatalogUiEnv()..results = [searchResultJson(id: productA)];
  env.lookups[shareableGtin] = {
    'status': 'found',
    'product': cardJson()['product'],
    'package': null,
    'composition': null,
  };
  return env;
}

Future<ProviderContainer> _openList(
  WidgetTester tester,
  CatalogUiEnv env, {
  bool withCatalog = true,
  Locale locale = const Locale('en'),
  String? foreignRole,
  bool withScope = true,
  bool senior = false,
}) async {
  final container = await env.pump(
    tester,
    configure: (scope) =>
        scope.read(settingsProvider.notifier).setSeniorMode(enabled: senior),
    withCatalog: withCatalog,
    locale: locale,
  );
  if (foreignRole == null) {
    goRoute(container, AppRoutes.medications);
  } else {
    await seedProfile(
      env.harness,
      role: foreignRole,
      withScope: withScope,
    );
    openRoute(container, AppRoutes.profileMedications('foreign-profile-1'));
  }
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('own profile', () {
    testWidgets('the button opens the add form with the scanner up', (
      tester,
    ) async {
      final env = _env();
      await _openList(tester, env);

      // An empty list offers the scan as its primary action (B2-EmptyMedications).
      expect(find.byKey(_scanButton), findsOneWidget);
      expect(find.text('Scan the package'), findsOneWidget);
      expect(env.scanners, isEmpty);

      await tester.tap(find.byKey(_scanButton));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('scan-manual')), findsOneWidget);
      expect(env.scanners, hasLength(1));

      await env.scan(tester, retailCode(shareableGtin));
      expect(find.byKey(const Key('catalog-linked')), findsOneWidget);
      expect(env.scanners, hasLength(1));
    });

    testWidgets('the label is Russian in the Russian locale', (tester) async {
      await _openList(tester, _env(), locale: const Locale('ru'));

      expect(find.text('Сканировать упаковку'), findsOneWidget);
    });

    testWidgets('closing the sheet leaves the form; it is not reopened', (
      tester,
    ) async {
      final env = _env();
      await _openList(tester, env);
      await tester.tap(find.byKey(_scanButton));
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-manual')), findsNothing);
      expect(find.byKey(const Key('med-name')), findsOneWidget);

      // A rebuild of the form must not start the scanner again.
      await tester.tap(find.byKey(const Key('med-zone-switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-manual')), findsNothing);
      expect(env.scanners, hasLength(1));
    });

    testWidgets('"+" in the app bar opens the plain form', (tester) async {
      final env = _env();
      await _openList(tester, env);

      await tester.tap(find.byKey(const Key('medications-add')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('med-name')), findsOneWidget);
      expect(find.byKey(const Key('scan-manual')), findsNothing);
      expect(env.scanners, isEmpty);
    });

    testWidgets('no catalog in the build, no scan button', (tester) async {
      await _openList(tester, _env(), withCatalog: false);

      expect(find.byKey(_scanButton), findsNothing);
      expect(find.byKey(const Key('medications-add')), findsOneWidget);
    });

    for (final senior in [false, true]) {
      testWidgets(
          'the last medication stays clear of the button, senior $senior', (
        tester,
      ) async {
        final env = _env();
        final container = await _openList(tester, env, senior: senior);
        final repository = container.read(medicationsRepositoryProvider);
        for (var i = 0; i < 8; i++) {
          await repository.create(
            profileId: selfProfileId,
            draft: MedicationDraft(name: 'Med $i'),
          );
        }
        // A short screen, so the list scrolls under the button.
        addTearDown(tester.view.reset);
        tester.view.physicalSize = const Size(390 * 3, 640 * 3);
        await tester.pumpAndSettle();

        await tester.drag(find.byType(ListView).first, const Offset(0, -5000));
        await tester.pumpAndSettle();

        final cards = find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('medication-'),
        );
        final lowest = [
          for (final element in cards.evaluate())
            tester.getBottomLeft(find.byWidget(element.widget)).dy,
        ].reduce((a, b) => a > b ? a : b);
        expect(cards, findsNWidgets(8));
        expect(
          lowest,
          lessThanOrEqualTo(tester.getTopLeft(find.byKey(_scanButton)).dy),
        );
      });
    }
  });

  group('deep link', () {
    testWidgets('the add route with scan=1 opens the scanner', (tester) async {
      final env = _env();
      final container = await env.pump(tester);
      openRoute(container, '${AppRoutes.newMedication}?scan=1');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('scan-manual')), findsOneWidget);
      expect(env.scanners, hasLength(1));
    });

    testWidgets('the add route of another profile does too', (tester) async {
      final env = _env();
      final container = await env.pump(tester);
      await seedProfile(env.harness, role: 'editor');
      openRoute(
        container,
        '${AppRoutes.newProfileMedication('foreign-profile-1')}?scan=1',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('scan-manual')), findsOneWidget);
      expect(env.scanners, hasLength(1));
    });

    testWidgets('scan=0 does not', (tester) async {
      final env = _env();
      final container = await env.pump(tester);
      openRoute(container, '${AppRoutes.newMedication}?scan=0');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('med-name')), findsOneWidget);
      expect(env.scanners, isEmpty);
    });
  });

  group('scan route helpers', () {
    test('scanEntryRoute adds scan=1', () {
      expect(scanEntryRoute('/add-medication'), '/add-medication?scan=1');
    });

    test('wantsScan is true only for scan=1', () {
      expect(wantsScan(Uri.parse('/x?scan=1')), isTrue);
      expect(wantsScan(Uri.parse('/x?scan=0')), isFalse);
      expect(wantsScan(Uri.parse('/x?scan=abc')), isFalse);
      expect(wantsScan(Uri.parse('/x')), isFalse);
    });
  });

  group('someone else\'s profile', () {
    testWidgets('an editor scans into that profile', (tester) async {
      final env = _env();
      await _openList(tester, env, foreignRole: 'editor');

      expect(find.byKey(_scanButton), findsOneWidget);
      await tester.tap(find.byKey(_scanButton));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('scan-manual')), findsOneWidget);
      expect(env.scanners, hasLength(1));
    });

    testWidgets('a viewer has no scan button', (tester) async {
      await _openList(tester, _env(), foreignRole: 'viewer');

      expect(find.byKey(_scanButton), findsNothing);
    });

    testWidgets('an unknown role has no scan button', (tester) async {
      await _openList(
        tester,
        _env(),
        foreignRole: 'guardian',
        withScope: false,
      );

      expect(find.byKey(_scanButton), findsNothing);
    });
  });
}
