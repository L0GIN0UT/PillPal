import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/features/catalog/scanner_adapter.dart';

import '../data/catalog_fixtures.dart';
import '../helpers.dart';
import 'catalog_ui_env.dart';
import 'fake_scanner.dart';

// Scanning in the medication form (4.11): the GTIN is resolved on the device
// first, then with one lookup; a restricted number never leaves the phone
// (D3); the serial and the expiry date of a marked pack are never kept or
// sent (D7); the opt-in box appears only when the catalog does not know the
// number (D2).

const String _serial = 'SN7Q9X2KLM4';
const String _expiry = '291130';
const String _signature = 'c2lnbmF0dXJl';

Map<String, Object?> _found() => {
      'status': 'found',
      'product': cardJson()['product'],
      'package': null,
      'composition': null,
    };

CatalogUiEnv _env({bool known = false}) {
  final env = CatalogUiEnv()..results = [searchResultJson(id: productA)];
  if (known) {
    env.lookups[shareableGtin] = _found();
  }
  return env;
}

bool? _boxValue(WidgetTester tester) => tester
    .widget<CheckboxListTile>(find.byKey(const Key('catalog-consent')))
    .value;

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

Future<void> _saveNamed(CatalogUiEnv env, WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('med-name')), 'My own pills');
  await env.save(tester);
}

Finder get _consentBox => find.byKey(const Key('catalog-consent'));

Future<void> _typeNumber(WidgetTester tester, String digits) async {
  await tester.tap(find.byKey(const Key('scan-manual')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('scan-manual-field')), digits);
  await _tapKey(tester, 'scan-manual-submit');
}

void main() {
  group('a number the catalog knows', () {
    testWidgets('a retail barcode links the product and fills the form', (
      tester,
    ) async {
      final env = _env(known: true);
      await env.pump(tester);
      await env.openNewForm(tester);

      await env.openAndScan(tester, retailCode(shareableGtin));

      expect(find.byKey(const Key('catalog-linked')), findsOneWidget);
      final name = tester.widget<TextField>(find.byKey(const Key('med-name')));
      expect(name.controller?.text, 'Synthetic Tablet');
      expect(env.traffic.requests.map((request) => request.url.path), [
        '/v1/gtins/lookup',
        '/v1/products/get',
      ]);
      expect(env.traffic.requests.first.body, '{"gtin":"$shareableGtin"}');
      expect(env.scanner.disposed, isTrue);

      await env.save(tester);
      final rows =
          await env.harness.db.select(env.harness.db.medications).get();
      expect(rows.single.catalogProductId, productA);
      expect(rows.single.gtin, shareableGtin);
      expect(rows.single.gtinLinkShared, isFalse);
    });

    testWidgets('the catalog already knows it: no opt-in box', (tester) async {
      final env = _env(known: true);
      await env.pump(tester);
      await env.openNewForm(tester);

      await env.openAndScan(tester, retailCode(shareableGtin));

      expect(_consentBox, findsNothing);
    });

    testWidgets('a marked pack: neither serial nor expiry is sent or kept', (
      tester,
    ) async {
      final env = _env(known: true);
      await env.pump(tester);
      await env.openNewForm(tester);

      await env.openAndScan(tester, markedPackCode());
      await env.save(tester);

      final rows =
          await env.harness.db.select(env.harness.db.medications).get();
      expect(rows.single.gtin, shareableGtin);
      final stored = jsonEncode(rows.single.toJson());
      final outbox = jsonEncode(await env.lastMedicationPayload());
      final everywhere = '${env.allRequestBodies}\n$stored\n$outbox';
      for (final secret in [_serial, _expiry, _signature, '91EE11']) {
        expect(everywhere, isNot(contains(secret)), reason: secret);
      }
      expect(env.traffic.requests.map((request) => request.url.path).toList(), [
        '/v1/gtins/lookup',
        '/v1/products/get',
      ]);
      expect(env.traffic.requests.first.body, '{"gtin":"$shareableGtin"}');
    });
  });

  group('offline and private numbers', () {
    testWidgets('a medication of the profile matches without any request', (
      tester,
    ) async {
      final env = _env()..catalogOffline = true;
      final container = await env.pump(tester);
      await env.seedLinked(container);
      await env.openNewForm(tester);

      await env.openAndScan(tester, retailCode(shareableGtin));
      // The same composition as the saved medication: keep it separate.
      await _tapKey(tester, 'catalog-link-separate');

      expect(find.byKey(const Key('catalog-linked-name')), findsOneWidget);
      expect(env.traffic.requests, isEmpty);
      expect(_consentBox, findsNothing);
    });

    testWidgets(
        'a matched medication whose card is not cached keeps the number',
        (tester) async {
      final env = _env()..catalogOffline = true;
      final container = await env.pump(tester);
      // Linked, but the card was never cached on this phone.
      await container.read(medicationsRepositoryProvider).create(
            profileId: selfProfileId,
            draft: const MedicationDraft(
              name: 'Existing',
              catalogLink: CatalogUiEnv.defaultLink,
            ),
          );
      await env.openNewForm(tester);

      await env.openAndScan(tester, retailCode(shareableGtin));

      expect(find.byKey(const Key('catalog-private-gtin')), findsOneWidget);
      expect(find.byKey(const Key('scan-private-unreachable')), findsOneWidget);
      expect(_consentBox, findsNothing);
    });

    testWidgets('a restricted number is kept privately, nothing is sent', (
      tester,
    ) async {
      final env = _env();
      await env.pump(tester);
      await env.openNewForm(tester);

      await env.openAndScan(tester, retailCode(restrictedGtin));

      expect(env.traffic.requests, isEmpty);
      expect(find.byKey(const Key('catalog-private-gtin')), findsOneWidget);
      expect(_consentBox, findsNothing);
      expect(find.byKey(const Key('scan-private-restricted')), findsOneWidget);

      await _saveNamed(env, tester);
      final rows =
          await env.harness.db.select(env.harness.db.medications).get();
      expect(rows.single.gtin, restrictedGtin);
      expect(rows.single.catalogProductId, isNull);
      expect(rows.single.gtinLinkShared, isFalse);
      expect(env.backendBodies.join(), isNot(contains(restrictedGtin)));
    });

    testWidgets('an unreachable catalog keeps the number privately', (
      tester,
    ) async {
      final env = _env()..catalogOffline = true;
      await env.pump(tester);
      await env.openNewForm(tester);

      await env.openAndScan(tester, retailCode(shareableGtin));

      expect(find.byKey(const Key('catalog-private-gtin')), findsOneWidget);
      expect(find.byKey(const Key('scan-private-unreachable')), findsOneWidget);
      expect(_consentBox, findsNothing);

      await _saveNamed(env, tester);
      final rows =
          await env.harness.db.select(env.harness.db.medications).get();
      expect(rows.single.gtin, shareableGtin);
      expect(rows.single.catalogProductId, isNull);
    });

    testWidgets('the private number can be removed again', (tester) async {
      final env = _env();
      await env.pump(tester);
      await env.openNewForm(tester);
      await env.openAndScan(tester, retailCode(restrictedGtin));

      await _tapKey(tester, 'catalog-unlink');

      expect(find.byKey(const Key('catalog-private-gtin')), findsNothing);
      expect(find.byKey(const Key('catalog-scan')), findsOneWidget);
    });
  });

  group('a number the catalog does not know (D2)', () {
    Future<CatalogUiEnv> unknownThenSearch(WidgetTester tester) async {
      final env = _env();
      await env.pump(tester);
      await env.openNewForm(tester);
      await env.openAndScan(tester, retailCode(otherShareableGtin));
      expect(find.byKey(const Key('scan-unknown')), findsOneWidget);
      await _tapKey(tester, 'scan-unknown-search');
      await tester.enterText(
        find.byKey(const Key('catalog-search-text')),
        'synthetic',
      );
      await _tapKey(tester, 'catalog-search-go');
      await tester.tap(find.byKey(const ValueKey('catalog-result-$productA')));
      await tester.pumpAndSettle();
      return env;
    }

    testWidgets('a product chosen by name keeps the scanned number', (
      tester,
    ) async {
      final env = await unknownThenSearch(tester);

      expect(find.byKey(const Key('catalog-linked')), findsOneWidget);
      await env.save(tester);
      final rows =
          await env.harness.db.select(env.harness.db.medications).get();
      expect(rows.single.catalogProductId, productA);
      expect(rows.single.gtin, otherShareableGtin, reason: 'not the card one');
      expect(rows.single.catalogPackageId, isNull);
    });

    testWidgets('offers the box, off by default; ticked it is sent', (
      tester,
    ) async {
      final env = await unknownThenSearch(tester);

      expect(_consentBox, findsOneWidget);
      expect(_boxValue(tester), isFalse);

      await _tapKey(tester, 'catalog-consent');
      await env.save(tester);

      final payload = await env.lastMedicationPayload();
      expect(payload['gtin'], otherShareableGtin);
      expect(payload['gtin_link_shared'], isTrue);
      expect(payload['gtin_link_consent_version'], 1);
    });

    testWidgets('left unticked, nothing is shared', (tester) async {
      final env = await unknownThenSearch(tester);

      await env.save(tester);

      final payload = await env.lastMedicationPayload();
      expect(payload['gtin_link_shared'], isFalse);
      expect(payload.containsKey('gtin_link_consent_version'), isFalse);
    });

    testWidgets('no box while the server does not accept contributions', (
      tester,
    ) async {
      final env = _env()..contributions = false;
      await env.pump(tester);
      await env.openNewForm(tester);
      await env.openAndScan(tester, retailCode(otherShareableGtin));
      await _tapKey(tester, 'scan-unknown-search');
      await tester.enterText(
        find.byKey(const Key('catalog-search-text')),
        'synthetic',
      );
      await _tapKey(tester, 'catalog-search-go');
      await tester.tap(find.byKey(const ValueKey('catalog-result-$productA')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('catalog-linked')), findsOneWidget);
      expect(_consentBox, findsNothing);
    });

    testWidgets('a disputed number links by name but never offers the box', (
      tester,
    ) async {
      final env = _env()..lookups[otherShareableGtin] = {'status': 'disputed'};
      await env.pump(tester);
      await env.openNewForm(tester);

      await env.openAndScan(tester, retailCode(otherShareableGtin));
      expect(find.byKey(const Key('scan-unknown')), findsOneWidget);
      await _tapKey(tester, 'scan-unknown-search');
      await tester.enterText(
        find.byKey(const Key('catalog-search-text')),
        'synthetic',
      );
      await _tapKey(tester, 'catalog-search-go');
      await tester.tap(find.byKey(const ValueKey('catalog-result-$productA')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('catalog-linked')), findsOneWidget);
      expect(_consentBox, findsNothing);
    });

    testWidgets('a product whose card lists the number gets no box', (
      tester,
    ) async {
      // The catalog answers "unknown", but the card chosen by name already
      // carries this GTIN: the catalog knows the pair, nothing to count.
      final env = _env();
      await env.pump(tester);
      await env.openNewForm(tester);

      await env.openAndScan(tester, retailCode(shareableGtin));
      await _tapKey(tester, 'scan-unknown-search');
      await tester.enterText(
        find.byKey(const Key('catalog-search-text')),
        'synthetic',
      );
      await _tapKey(tester, 'catalog-search-go');
      await tester.tap(find.byKey(const ValueKey('catalog-result-$productA')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('catalog-linked')), findsOneWidget);
      expect(_consentBox, findsNothing);
    });

    testWidgets('"keep the number only" stores it without a product', (
      tester,
    ) async {
      final env = _env();
      await env.pump(tester);
      await env.openNewForm(tester);
      await env.openAndScan(tester, retailCode(otherShareableGtin));

      await _tapKey(tester, 'scan-unknown-keep');

      expect(find.byKey(const Key('catalog-private-gtin')), findsOneWidget);
      expect(_consentBox, findsNothing);
      await _saveNamed(env, tester);
      final rows =
          await env.harness.db.select(env.harness.db.medications).get();
      expect(rows.single.gtin, otherShareableGtin);
      expect(rows.single.catalogProductId, isNull);
    });

    testWidgets('cancelling changes nothing', (tester) async {
      final env = _env();
      await env.pump(tester);
      await env.openNewForm(tester);
      await env.openAndScan(tester, retailCode(otherShareableGtin));

      await _tapKey(tester, 'scan-unknown-cancel');

      expect(find.byKey(const Key('catalog-linked')), findsNothing);
      expect(find.byKey(const Key('catalog-private-gtin')), findsNothing);
      expect(find.byKey(const Key('catalog-scan')), findsOneWidget);
    });

    testWidgets('a typed number is offered the box the same way', (
      tester,
    ) async {
      final env = _env();
      await env.pump(tester);
      await env.openNewForm(tester);
      await env.openScan(tester);

      await _typeNumber(tester, '4607000000014');
      await _tapKey(tester, 'scan-unknown-search');
      await tester.enterText(
        find.byKey(const Key('catalog-search-text')),
        'synthetic',
      );
      await _tapKey(tester, 'catalog-search-go');
      await tester.tap(find.byKey(const ValueKey('catalog-result-$productA')));
      await tester.pumpAndSettle();

      expect(_consentBox, findsOneWidget);
      expect(_boxValue(tester), isFalse);
    });
  });

  group('without a camera', () {
    testWidgets('a denied permission still reaches the product by number', (
      tester,
    ) async {
      final env = _env(known: true);
      await env.pump(tester);
      await env.openNewForm(tester);
      await env.openScan(tester);

      env.scanner.fail(ScannerFailure.permissionDenied);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('scan-manual-field')),
        '4607000000007',
      );
      await _tapKey(tester, 'scan-manual-submit');

      expect(find.byKey(const Key('catalog-linked')), findsOneWidget);
    });

    testWidgets('the scan button is part of the catalog UI only', (
      tester,
    ) async {
      final env = _env();
      await env.pump(tester, withCatalog: false);
      await env.openNewForm(tester);

      expect(find.byKey(const Key('catalog-scan')), findsNothing);
    });
  });
}
