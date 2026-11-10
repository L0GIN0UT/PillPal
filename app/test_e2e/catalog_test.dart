import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/catalog/catalog_link.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/features/catalog/catalog_fill.dart';

import 'device.dart';

// End-to-end of the catalog journeys (milestone 4.12, CI job "app / e2e"):
// the real backend and the real catalog service loaded with the synthetic
// fixture (`catalog/tests/fixtures/fixture/v1`). Needs
// PILLPAL_E2E_BASE_URL, PILLPAL_E2E_LOG, PILLPAL_E2E_CATALOG_URL and, for the
// consensus journey, PILLPAL_E2E_AGGREGATE_CMD (a shell command that runs the
// backend's aggregate once: `.github/scripts/e2e/catalog_aggregate.py`);
// skipped otherwise. The account names start with `e2e-catalog-`, which is
// what that script backdates.

const String _password = 'e2e-password-1';

/// A package of the synthetic "Testamol 500" (two packages, so the link of
/// its card carries no package until the GTIN says which one).
const String _knownGtin = '4607012345677';
const String _knownGtin14 = '04607012345677';

/// A valid, shareable number that no fixture product carries.
const String _unknownGtin = '4601234567893';
const String _unknownGtin14 = '04601234567893';

/// The synthetic combination product: no package, no number.
const String _combinoSearch = 'Fixtocombo';

Future<Device> _newDevice(Uri baseUrl, Uri catalogUrl) async {
  final device = Device(baseUrl, catalogUrl: catalogUrl);
  addTearDown(device.close);
  return device;
}

Future<Device> _signedUp(
  Uri baseUrl,
  Uri catalogUrl,
  String logPath,
  String label,
) async {
  final device = await _newDevice(baseUrl, catalogUrl);
  final stamp = DateTime.now().microsecondsSinceEpoch;
  await device.signUp(
    email: 'e2e-catalog-$label-$stamp@example.com',
    password: _password,
    logPath: logPath,
  );
  await device.sync();
  return device;
}

Future<String> _selfProfile(Device device) async =>
    (await device.profiles.watchAll().first).single.id;

/// The id of the one product a search by [query] finds.
Future<String> _productId(Device device, String query, String name) async {
  final response = await device.catalog.search(
    q: query,
    lang: 'en',
    market: 'ru',
  );
  final found = response.results.where(
    (result) => result.kind == 'product' && result.name == name,
  );
  expect(found, hasLength(1), reason: 'search "$query" finds "$name" once');
  return found.single.id;
}

Future<List<MedicationRow>> _medications(Device device) {
  return device.db.select(device.db.medications).get();
}

/// Runs the backend's aggregate once, like the worker would.
Future<void> _runAggregate(String command) async {
  final result = await Process.run('sh', ['-c', command]);
  expect(
    result.exitCode,
    0,
    reason: 'the aggregate command failed: ${result.stderr}',
  );
}

void main() {
  final base = Platform.environment['PILLPAL_E2E_BASE_URL'];
  final logPath = Platform.environment['PILLPAL_E2E_LOG'];
  final catalog = Platform.environment['PILLPAL_E2E_CATALOG_URL'];
  final aggregate = Platform.environment['PILLPAL_E2E_AGGREGATE_CMD'];
  final skip = base == null || logPath == null || catalog == null
      ? 'PILLPAL_E2E_BASE_URL / PILLPAL_E2E_LOG / PILLPAL_E2E_CATALOG_URL '
          'not set'
      : null;
  final skipConsensus = skip ??
      (aggregate == null ? 'PILLPAL_E2E_AGGREGATE_CMD not set' : null);

  test(
    'search, select and save; a second device pulls the references',
    () async {
      final baseUrl = Uri.parse(base!);
      final catalogUrl = Uri.parse(catalog!);
      final email = 'e2e-catalog-pull-'
          '${DateTime.now().microsecondsSinceEpoch}@example.com';
      final a = await _newDevice(baseUrl, catalogUrl);
      final b = await _newDevice(baseUrl, catalogUrl);
      await a.signUp(email: email, password: _password, logPath: logPath!);
      await b.auth.login(email: email, password: _password);
      await a.sync();

      // Search -> select: the card of the product, then the link the form
      // would build for a typed number that one of its packages carries.
      final productId = await _productId(a, 'Testamol', 'Testamol 500');
      final card = await a.catalog.product(productId);
      expect(card.packages, hasLength(2));
      final link = withGtin(catalogLinkOf(card), _knownGtin, card: card);
      expect(link.gtin, _knownGtin14);
      expect(link.packageId, isNotNull, reason: 'the package of the number');
      expect(link.compositionId, card.composition?.id);
      final texts = catalogTexts(card, 'en');

      // Save: free text stays authoritative, the references ride along.
      await a.medications.create(
        profileId: await _selfProfile(a),
        draft: MedicationDraft(
          name: texts[CatalogTextField.name]!,
          form: texts[CatalogTextField.form],
          strengthText: texts[CatalogTextField.strength],
          catalogLink: link,
        ),
      );
      await a.sync();

      // The second device pulls the same references, no consent among them.
      await b.sync();
      final pulled = (await _medications(b)).single;
      expect(CatalogLink.fromRow(pulled), link);
      expect(pulled.name, 'Testamol 500');
      expect(pulled.gtinLinkShared, isFalse);
      expect((await _medications(a)).single.catalogProductId, productId);

      // The references resolve at the catalog from the other device.
      final reopened = await b.catalog.product(pulled.catalogProductId!);
      expect(reopened.product.name, 'Testamol 500');
      expect(
        reopened.packages.map((package) => package.id),
        contains(pulled.catalogPackageId),
      );
      final lookup = await b.catalog.lookupGtin(_knownGtin);
      expect(lookup.status, 'found');
      expect(lookup.product?.id, productId);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'an unknown number is promoted once three accounts opted in',
    () async {
      final baseUrl = Uri.parse(base!);
      final catalogUrl = Uri.parse(catalog!);
      final devices = <Device>[
        for (final label in ['one', 'two', 'three'])
          await _signedUp(baseUrl, catalogUrl, logPath!, label),
      ];
      expect(
        (await devices.first.catalog.lookupGtin(_unknownGtin)).status,
        'unknown',
        reason: 'nothing links this number yet',
      );
      final productId =
          await _productId(devices.first, _combinoSearch, 'Fixtocombo');
      final card = await devices.first.catalog.product(productId);
      final linked = withGtin(catalogLinkOf(card), _unknownGtin, card: card);
      expect(linked.gtin, _unknownGtin14);
      expect(linked.packageId, isNull, reason: 'no package carries it');

      // Each person typed the number, picked the product by name and ticked
      // the box: a consent record of the server, one follow-up write.
      Future<void> optIn(Device device) async {
        await device.medications.create(
          profileId: await _selfProfile(device),
          draft: MedicationDraft(
            name: 'Combo of ${device.email.split('@').first}',
            catalogLink: withConsentTick(linked),
          ),
        );
        await device.sync();
      }

      // Two accounts are not enough: the aggregate carries the count 2 and
      // the catalog keeps waiting for the third (owner decision D8).
      await optIn(devices[0]);
      await optIn(devices[1]);
      await _runAggregate(aggregate!);
      expect(
        (await devices.first.catalog.lookupGtin(_unknownGtin)).status,
        'unknown',
        reason: 'two confirmations do not promote',
      );

      await optIn(devices[2]);
      await _runAggregate(aggregate);
      final lookup = await devices.last.catalog.lookupGtin(_unknownGtin);
      expect(lookup.status, 'found', reason: 'three confirmations promote');
      expect(lookup.product?.id, productId);
      expect(lookup.package?.gtins, contains(_unknownGtin14));

      // The card carries the number now: it was learned, not imported.
      final promoted = await devices.last.catalog.product(productId);
      expect(
        promoted.packages.any((p) => p.gtins.contains(_unknownGtin14)),
        isTrue,
      );
    },
    skip: skipConsensus,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
