import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/catalog/catalog_dto.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../data/catalog_fixtures.dart';
import '../family/family_fixtures.dart' show seedForeignMedication, seedProfile;
import '../helpers.dart';
import 'catalog_ui_env.dart';

// The same composition as an existing medication (D4) and the neutral
// "both contain" hint (D9): computed on the device from cached cards, the
// prompt links the package to the existing medication and never blocks.

/// An existing medication X with product A, stock and a schedule, and a
/// catalog that offers product B with the same composition.
Future<({CatalogUiEnv env, String medication})> _sameComposition(
  WidgetTester tester,
) async {
  final env = CatalogUiEnv()
    ..cards[productB] = cardJson(productId: productB)
    ..results = [searchResultJson(id: productB, name: 'Other brand')];
  final container = await env.pump(tester);
  final id = await env.seedLinked(container, stockCount: '10');
  await env.harness.seedSchedule(container, id, testRule());
  await env.openNewForm(tester);
  return (env: env, medication: id);
}

Future<List<MedicationRow>> _medications(CatalogUiEnv env) =>
    env.harness.db.select(env.harness.db.medications).get();

void main() {
  group('same composition (D4)', () {
    testWidgets('links the package to the existing medication', (tester) async {
      final (:env, :medication) = await _sameComposition(tester);

      await env.searchAndPick(tester, 'other', productB);

      expect(find.byKey(const Key('catalog-link-prompt')), findsOneWidget);
      expect(
        find.text(
          'This is the same composition as “Existing”. '
          'Link the package to it?',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('catalog-link-existing')));
      await tester.pumpAndSettle();

      final rows = await _medications(env);
      expect(rows, hasLength(1), reason: 'no new medication');
      final row = rows.single;
      expect(row.id, medication);
      expect(row.name, 'Existing');
      expect(row.stockCount, '10');
      expect(row.catalogProductId, productB);
      expect(row.catalogCompositionId, compositionA);
      expect(row.gtin, shareableGtin);
      expect(row.gtinLinkShared, isFalse);
      final schedules =
          await env.harness.db.select(env.harness.db.schedules).get();
      expect(schedules, hasLength(1));
      // The form is closed and the card is kept for the medication.
      expect(find.byKey(const Key('med-save')), findsNothing);
      expect(find.textContaining('linked to “Existing”'), findsOneWidget);
      final cached =
          await env.harness.db.select(env.harness.db.catalogCache).get();
      expect(cached.map((row) => row.id), [productB]);
    });

    testWidgets('"create separately" goes on with the form', (tester) async {
      final (:env, medication: _) = await _sameComposition(tester);

      await env.searchAndPick(tester, 'other', productB);
      await tester.tap(find.byKey(const Key('catalog-link-separate')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('catalog-linked')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('med-name')))
            .controller!
            .text,
        'Synthetic Tablet',
      );
      await env.save(tester);
      final rows = await _medications(env);
      expect(rows, hasLength(2));
      expect(
          rows.where((row) => row.catalogProductId == productB), hasLength(1));
      expect(
        rows.singleWhere((row) => row.name == 'Existing').catalogProductId,
        productA,
      );
    });

    testWidgets('a search never offers the box, even in the prompt',
        (tester) async {
      final (:env, medication: _) = await _sameComposition(tester);
      await env.searchAndPick(tester, 'other', productB);
      expect(find.byKey(const Key('catalog-link-prompt')), findsOneWidget);
      expect(find.byKey(const Key('catalog-consent')), findsNothing);

      await tester.tap(find.byKey(const Key('catalog-link-existing')));
      await tester.pumpAndSettle();

      final payload = await env.lastMedicationPayload();
      expect(payload['gtin_link_shared'], isFalse);
      expect(payload.containsKey('gtin_link_consent_version'), isFalse);
    });

    testWidgets('a typed GTIN offers the box in the prompt; ticked it is sent',
        (tester) async {
      final (:env, medication: _) = await _sameComposition(tester);
      await pickWithGtin(tester, productB);
      expect(find.byKey(const Key('catalog-link-prompt')), findsOneWidget);
      expect(find.byKey(const Key('catalog-consent')), findsOneWidget);

      await tester.tap(find.byKey(const Key('catalog-consent')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('catalog-link-existing')));
      await tester.pumpAndSettle();

      final payload = await env.lastMedicationPayload();
      expect(payload['catalog_product_id'], productB);
      expect(payload['gtin_link_shared'], isTrue);
      expect(payload['gtin_link_consent_version'], 1);
    });

    testWidgets('an untouched box in the prompt sends shared = false',
        (tester) async {
      final (:env, medication: _) = await _sameComposition(tester);
      await pickWithGtin(tester, productB);

      await tester.tap(find.byKey(const Key('catalog-link-existing')));
      await tester.pumpAndSettle();

      final payload = await env.lastMedicationPayload();
      expect(payload['gtin_link_shared'], isFalse);
      expect(payload.containsKey('gtin_link_consent_version'), isFalse);
    });

    testWidgets('with several matches the person chooses which one',
        (tester) async {
      final (:env, medication: first) = await _sameComposition(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      final second = await env.seedLinked(container, name: 'Second');
      await tester.pumpAndSettle();

      await env.searchAndPick(tester, 'other', productB);
      expect(
        find.byKey(ValueKey('catalog-link-choice-$first')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(ValueKey('catalog-link-choice-$second')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('catalog-link-existing')));
      await tester.pumpAndSettle();

      final rows = await _medications(env);
      expect(rows, hasLength(2));
      expect(
        rows.singleWhere((row) => row.id == second).catalogProductId,
        productB,
      );
      expect(
        rows.singleWhere((row) => row.id == first).catalogProductId,
        productA,
      );
    });

    testWidgets('linking from the form of an existing medication keeps it open',
        (tester) async {
      final env = CatalogUiEnv()
        ..cards[productB] = cardJson(productId: productB)
        ..results = [searchResultJson(id: productB)];
      final container = await env.pump(tester);
      await env.seedLinked(container, name: 'Existing');
      final other = await env.harness.seedMedication(container, name: 'Other');
      openRoute(container, AppRoutes.medication(other));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('med-name')), 'Unsaved edit');

      await env.searchAndPick(tester, 'other', productB);
      await tester.tap(find.byKey(const Key('catalog-link-existing')));
      await tester.pumpAndSettle();

      // The edits are still in the form; nothing was discarded.
      expect(find.byKey(const Key('med-save')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('med-name')))
            .controller!
            .text,
        'Unsaved edit',
      );
      final rows = await _medications(env);
      expect(
        rows.singleWhere((row) => row.name == 'Existing').catalogProductId,
        productB,
      );
    });

    testWidgets('a cache failure does not fail a linked package',
        (tester) async {
      final env = CatalogUiEnv()
        ..cards[productB] = cardJson(productId: productB)
        ..results = [searchResultJson(id: productB)];
      final container = await env.pump(
        tester,
        extra: [
          catalogCacheRepositoryProvider
              .overrideWithValue(FailingRememberCache(env)),
        ],
      );
      await env.seedLinked(container);
      await env.openNewForm(tester);

      await env.searchAndPick(tester, 'other', productB);
      await tester.tap(find.byKey(const Key('catalog-link-existing')));
      await tester.pumpAndSettle();

      final rows = await _medications(env);
      expect(rows, hasLength(1));
      expect(rows.single.catalogProductId, productB);
      expect(find.byKey(const Key('med-save')), findsNothing);
    });

    testWidgets('a cache failure never makes a saved medication look failed',
        (tester) async {
      final env = CatalogUiEnv()..results = [searchResultJson(id: productA)];
      await env.pump(
        tester,
        extra: [
          catalogCacheRepositoryProvider
              .overrideWithValue(FailingRememberCache(env)),
        ],
      );
      await env.openNewForm(tester);
      await env.searchAndPick(tester, 'synthetic', productA);

      await env.save(tester);

      final rows = await _medications(env);
      expect(rows, hasLength(1), reason: 'saved once, not retried');
      expect(find.byKey(const Key('schedule-save')), findsOneWidget);
    });

    testWidgets('an incomplete composition never counts as the same',
        (tester) async {
      final env = CatalogUiEnv()
        ..cards[productB] = cardJson(productId: productB, complete: false)
        ..results = [searchResultJson(id: productB)];
      final container = await env.pump(tester);
      await env.seedLinked(container);
      await env.openNewForm(tester);

      await env.searchAndPick(tester, 'other', productB);

      expect(find.byKey(const Key('catalog-link-prompt')), findsNothing);
      expect(find.byKey(const Key('catalog-linked')), findsOneWidget);
    });

    testWidgets('another profile is never compared', (tester) async {
      final env = CatalogUiEnv()
        ..cards[productB] = cardJson(productId: productB)
        ..results = [searchResultJson(id: productB)];
      final container = await env.pump(tester);
      await env.seedLinked(container);

      // A new medication of a managed profile the account guards.
      final profile = await seedProfile(
        env.harness,
        id: 'managed-1',
        kind: 'managed',
        role: 'guardian',
      );
      openRoute(container, AppRoutes.newProfileMedication(profile));
      await tester.pumpAndSettle();
      await env.searchAndPick(tester, 'other', productB);

      expect(find.byKey(const Key('catalog-link-prompt')), findsNothing);
      expect(find.byKey(const Key('catalog-linked')), findsOneWidget);
    });
  });

  group('"both contain" hint (D9)', () {
    Future<CatalogUiEnv> overlapping(WidgetTester tester, Locale locale) async {
      final env = CatalogUiEnv()
        ..cards[productB] = cardJson(
          productId: productB,
          compositionId: 'a16f0ab8-4e71-4fc6-8d91-6a8f9c5d7e77',
        )
        ..results = [searchResultJson(id: productB)];
      final container = await env.pump(tester, locale: locale);
      await env.seedLinked(container);
      await env.openNewForm(tester);
      await env.searchAndPick(tester, 'other', productB);
      return env;
    }

    testWidgets('is neutral in English and never blocks saving',
        (tester) async {
      final env = await overlapping(tester, const Locale('en'));

      expect(find.text('Both contain: Substance'), findsOneWidget);
      expect(find.byKey(const Key('catalog-link-prompt')), findsNothing);
      await env.save(tester);
      expect(await _medications(env), hasLength(2));
      expect(find.byKey(const Key('schedule-save')), findsOneWidget);
    });

    testWidgets('is neutral in Russian', (tester) async {
      await overlapping(tester, const Locale('ru'));

      expect(find.text('Оба содержат: Вещество'), findsOneWidget);
    });

    testWidgets('can be dismissed', (tester) async {
      await overlapping(tester, const Locale('en'));

      await tester.tap(find.byKey(const Key('catalog-overlap-dismiss')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('catalog-overlap')), findsNothing);
    });

    testWidgets('a relative who edits gets no hint', (tester) async {
      final env = CatalogUiEnv()
        ..cards[productB] = cardJson(
          productId: productB,
          compositionId: 'a16f0ab8-4e71-4fc6-8d91-6a8f9c5d7e77',
        )
        ..results = [searchResultJson(id: productB)];
      final container = await env.pump(tester);
      final profile = await seedProfile(env.harness, role: 'editor');
      final seeded = await seedForeignMedication(
        env.harness,
        container,
        profile,
      );
      await container.read(medicationsRepositoryProvider).create(
            profileId: profile,
            draft: const MedicationDraft(
              name: 'Shared with relative',
              catalogLink: CatalogUiEnv.defaultLink,
            ),
          );
      await container
          .read(catalogCacheRepositoryProvider)
          .remember(ProductCard.fromJson(cardJson()));
      openRoute(container, AppRoutes.medication(seeded.medication));
      await tester.pumpAndSettle();

      await env.searchAndPick(tester, 'other', productB);

      expect(find.byKey(const Key('catalog-linked')), findsOneWidget);
      expect(find.byKey(const Key('catalog-overlap')), findsNothing);
    });

    testWidgets('free-text names never produce a hint', (tester) async {
      final env = CatalogUiEnv()
        ..cards[productB] = cardJson(
          productId: productB,
          compositionId: 'a16f0ab8-4e71-4fc6-8d91-6a8f9c5d7e77',
          substances: const [substanceY],
        )
        ..results = [searchResultJson(id: productB)];
      final container = await env.pump(tester);
      await env.seedLinked(container);
      await env.openNewForm(tester);

      await env.searchAndPick(tester, 'other', productB);

      expect(find.byKey(const Key('catalog-overlap')), findsNothing);
    });
  });
}
