import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/catalog/catalog_link.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../data/catalog_fixtures.dart';
import '../family/family_fixtures.dart' show seedForeignMedication, seedProfile;
import '../helpers.dart';
import 'catalog_ui_env.dart';

// Selecting a catalog product in the form (ADR 0015 §4, §5): D5 (fill only
// empty fields, explicit replace offers) and the consent rules (the box only
// at link time, default off, online only, full-access roles only).

CatalogUiEnv _envWithResult() {
  return CatalogUiEnv()..results = [searchResultJson(id: productA)];
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

String _text(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

bool? _boxValue(WidgetTester tester) => tester
    .widget<CheckboxListTile>(find.byKey(const Key('catalog-consent')))
    .value;

void main() {
  group('selecting a product (D5)', () {
    testWidgets('fills the empty fields and links the references',
        (tester) async {
      final env = _envWithResult();
      await env.pump(tester);
      await env.openNewForm(tester);

      await env.searchAndPick(tester, 'synthetic', productA);

      expect(_text(tester, 'med-name'), 'Synthetic Tablet');
      expect(_text(tester, 'med-form'), 'tablets');
      expect(_text(tester, 'med-strength'), '500 mg');
      expect(find.byKey(const Key('catalog-linked')), findsOneWidget);
      expect(find.byKey(const Key('catalog-linked-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('catalog-offer-name')), findsNothing);

      await env.save(tester);
      final rows =
          await env.harness.db.select(env.harness.db.medications).get();
      expect(rows.single.name, 'Synthetic Tablet');
      expect(rows.single.catalogProductId, productA);
      expect(rows.single.catalogCompositionId, compositionA);
      expect(rows.single.gtin, shareableGtin);
      // The card is kept for offline use, without a second request.
      final cached =
          await env.harness.db.select(env.harness.db.catalogCache).get();
      expect(cached.map((row) => row.id), [productA]);
      expect(
        env.traffic.requests.map((request) => request.url.path),
        ['/v1/search', '/v1/products/get'],
      );
    });

    testWidgets('a filled field is offered a replacement and stays as typed',
        (tester) async {
      final env = _envWithResult();
      await env.pump(tester);
      await env.openNewForm(tester);
      await tester.enterText(find.byKey(const Key('med-name')), 'My own name');

      await env.searchAndPick(tester, 'synthetic', productA);

      expect(_text(tester, 'med-name'), 'My own name');
      expect(_text(tester, 'med-form'), 'tablets');
      expect(find.byKey(const ValueKey('catalog-offer-name')), findsOneWidget);
      expect(
        find.text('Replace Name with “Synthetic Tablet”?'),
        findsOneWidget,
      );

      await _tapKey(tester, 'catalog-offer-replace-name');
      expect(_text(tester, 'med-name'), 'Synthetic Tablet');
      expect(find.byKey(const ValueKey('catalog-offer-name')), findsNothing);
    });

    testWidgets('declining an offer keeps the text and closes the offer',
        (tester) async {
      final env = _envWithResult();
      await env.pump(tester);
      await env.openNewForm(tester);
      await tester.enterText(find.byKey(const Key('med-strength')), '1 g');
      await env.searchAndPick(tester, 'synthetic', productA);

      await _tapKey(tester, 'catalog-offer-keep-strength');

      expect(_text(tester, 'med-strength'), '1 g');
      expect(
        find.byKey(const ValueKey('catalog-offer-strength')),
        findsNothing,
      );
    });

    testWidgets('unlinking keeps the typed text and clears the references',
        (tester) async {
      final env = CatalogUiEnv();
      final container = await env.pump(tester);
      final id = await env.seedLinked(container, name: 'Kept name');

      openRoute(container, AppRoutes.medication(id));
      await tester.pumpAndSettle();
      await _tapKey(tester, 'catalog-unlink');
      expect(find.byKey(const Key('med-catalog')), findsOneWidget);
      await env.save(tester);

      final row =
          (await env.harness.db.select(env.harness.db.medications).get())
              .single;
      expect(row.name, 'Kept name');
      expect(row.catalogProductId, isNull);
      expect(row.gtin, isNull);
      expect(row.gtinLinkShared, isFalse);
    });

    testWidgets('a product that cannot be opened offline changes nothing',
        (tester) async {
      final env = _envWithResult();
      await env.pump(tester);
      await env.openNewForm(tester);
      await env.search(tester, 'synthetic');
      env.catalogOffline = true;
      await tester.tap(find.byKey(const ValueKey('catalog-result-$productA')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('catalog-linked')), findsNothing);
      expect(_text(tester, 'med-name'), isEmpty);
      expect(
        find.text(
          'Catalog search needs an internet connection. '
          'You can still enter the medication manually.',
        ),
        findsOneWidget,
      );
    });
  });

  group('the opt-in to count the link', () {
    testWidgets('is offered unticked and sends nothing unless ticked',
        (tester) async {
      final env = _envWithResult();
      await env.pump(tester);
      await env.openNewForm(tester);
      await env.searchAndPick(tester, 'synthetic', productA);

      expect(find.byKey(const Key('catalog-consent')), findsOneWidget);
      expect(_boxValue(tester), isFalse);
      await env.save(tester);

      final payload = await env.lastMedicationPayload();
      expect(payload['catalog_product_id'], productA);
      expect(payload['gtin_link_shared'], isFalse);
      expect(payload.containsKey('gtin_link_consent_version'), isFalse);
    });

    testWidgets('ticking records the consent version once', (tester) async {
      final env = _envWithResult();
      await env.pump(tester);
      await env.openNewForm(tester);
      await env.searchAndPick(tester, 'synthetic', productA);

      await _tapKey(tester, 'catalog-consent');
      expect(_boxValue(tester), isTrue);
      await env.save(tester);

      final payload = await env.lastMedicationPayload();
      expect(payload['gtin_link_shared'], isTrue);
      expect(payload['gtin_link_consent_version'], 1);
      final row =
          (await env.harness.db.select(env.harness.db.medications).get())
              .single;
      expect(row.gtinLinkShared, isTrue);
    });

    testWidgets('is disabled and says "available online" when offline',
        (tester) async {
      final env = _envWithResult()..backendOffline = true;
      await env.pump(tester);
      await env.openNewForm(tester);
      await env.searchAndPick(tester, 'synthetic', productA);

      expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('catalog-consent')))
            .onChanged,
        isNull,
      );
      expect(find.text('Available online.'), findsOneWidget);
      await env.save(tester);
      final payload = await env.lastMedicationPayload();
      expect(payload['gtin_link_shared'], isFalse);
    });

    testWidgets('is disabled while the server does not take contributions',
        (tester) async {
      final env = _envWithResult()..contributions = false;
      await env.pump(tester);
      await env.openNewForm(tester);
      await env.searchAndPick(tester, 'synthetic', productA);

      expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const Key('catalog-consent')))
            .onChanged,
        isNull,
      );
      expect(
          find.byKey(const Key('catalog-consent-online-only')), findsOneWidget);
    });

    testWidgets('is not offered for a product with several packages',
        (tester) async {
      final env = _envWithResult();
      final card = cardJson();
      (card['packages']! as List<Object?>).add({
        'id': '7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a34',
        'gtins': [otherShareableGtin],
        'count': '60',
        'count_unit': 'tablet',
        'description': null,
        'withdrawn': false,
      });
      env.cards[productA] = card;
      await env.pump(tester);
      await env.openNewForm(tester);

      await env.searchAndPick(tester, 'synthetic', productA);

      expect(find.byKey(const Key('catalog-linked')), findsOneWidget);
      expect(find.byKey(const Key('catalog-consent')), findsNothing);
      await env.save(tester);
      final row =
          (await env.harness.db.select(env.harness.db.medications).get())
              .single;
      expect(row.catalogProductId, productA);
      expect(row.catalogPackageId, isNull);
      expect(row.gtin, isNull);
    });

    testWidgets('re-linking an already counted medication resets the consent',
        (tester) async {
      final env = _envWithResult()
        ..cards[productB] = cardJson(productId: productB);
      env.results = [searchResultJson(id: productB)];
      final container = await env.pump(tester);
      final id = await env.seedLinked(
        container,
        link: const CatalogLink(
          productId: productA,
          packageId: '7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a33',
          compositionId: compositionA,
          gtin: shareableGtin,
          shared: true,
          consentVersion: 1,
        ),
      );
      openRoute(container, AppRoutes.medication(id));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('catalog-consent-active')),
        findsOneWidget,
      );

      await _tapKey(tester, 'catalog-unlink');
      await env.searchAndPick(tester, 'synthetic', productB);
      // A new pair: the box is offered again, unticked.
      expect(_boxValue(tester), isFalse);
      await env.save(tester);

      final payload = await env.lastMedicationPayload();
      expect(payload['catalog_product_id'], productB);
      expect(payload['gtin_link_shared'], isFalse);
      expect(payload.containsKey('gtin_link_consent_version'), isFalse);
    });

    testWidgets('an unchanged counted pair can be switched off',
        (tester) async {
      final env = CatalogUiEnv();
      final container = await env.pump(tester);
      final id = await env.seedLinked(
        container,
        link: const CatalogLink(
          productId: productA,
          packageId: '7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a33',
          compositionId: compositionA,
          gtin: shareableGtin,
          shared: true,
          consentVersion: 1,
        ),
      );
      openRoute(container, AppRoutes.medication(id));
      await tester.pumpAndSettle();

      await _tapKey(tester, 'catalog-consent-active');
      expect(find.byKey(const Key('catalog-consent-active')), findsNothing);
      await env.save(tester);

      final row =
          (await env.harness.db.select(env.harness.db.medications).get())
              .single;
      expect(row.catalogProductId, productA);
      expect(row.gtinLinkShared, isFalse);
    });

    testWidgets('an editor never sees the box and sends no consent',
        (tester) async {
      final env = _envWithResult();
      final container = await env.pump(tester);
      final profile = await seedProfile(env.harness, role: 'editor');
      final seeded = await seedForeignMedication(
        env.harness,
        container,
        profile,
      );
      openRoute(container, AppRoutes.medication(seeded.medication));
      await tester.pumpAndSettle();

      await env.searchAndPick(tester, 'synthetic', productA);

      expect(find.byKey(const Key('catalog-linked')), findsOneWidget);
      expect(find.byKey(const Key('catalog-consent')), findsNothing);
      await env.save(tester);
      final payload = await env.lastMedicationPayload();
      expect(payload['gtin_link_shared'], isNot(isTrue));
      expect(jsonEncode(payload), isNot(contains('consent_version')));
    });
  });
}
