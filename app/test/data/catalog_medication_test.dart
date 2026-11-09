import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/catalog/catalog_link.dart';
import 'package:pillpal/src/data/catalog/manual_ingredient.dart';
import 'package:pillpal/src/data/repositories/local_writer.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';

import 'test_env.dart';

// The medication's catalog references and the consent to count the link
// (ADR 0015 §4): what is stored and what the push carries; see
// catalog_medication_roles_test.dart for other roles and pulled rows.

const String _product = '5b0f4a52-8e1b-4f60-9d3b-0a2f3c9d1e11';
const String _otherProduct = '6c1a5b63-9f2c-4a71-8e4c-1b3a4d0e2f22';
const String _package = '7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a33';
const String _composition = '8e3c7d85-1b4e-4c93-8a6e-3d5c6f2a4b44';
const String _substance = '9f4d8e96-2c5f-4da4-9b7f-4e6d7a3b5c55';
const String _gtin = '04600000000011';
const String _otherGtin = '04600000000028';

const CatalogLink _link = CatalogLink(
  productId: _product,
  packageId: _package,
  compositionId: _composition,
  gtin: _gtin,
);

CatalogLink _ticked({String gtin = _gtin, String product = _product}) {
  return CatalogLink(
    productId: product,
    packageId: _package,
    gtin: gtin,
    shared: true,
    consentVersion: 1,
  );
}

void main() {
  late TestEnv env;
  late String medication;

  setUp(() async {
    env = await TestEnv.create();
    medication = (await env.seedLocal()).medication;
  });
  tearDown(() => env.dispose());

  Future<Map<String, Object?>> lastPayload() async {
    final entry = (await env.outbox()).last;
    return jsonDecode(entry.payload!) as Map<String, Object?>;
  }

  Future<void> saveLinked(CatalogLink link) {
    final draft = MedicationDraft(name: 'Med A', catalogLink: link);
    return env.medications.update(medication, draft);
  }

  group('payload', () {
    test('always carries the catalog fields', () async {
      final entries = await env.outbox();
      final entry = entries.firstWhere((e) => e.entityKind == 'medication');
      final payload = jsonDecode(entry.payload!) as Map<String, Object?>;

      for (final key in const [
        'catalog_product_id',
        'catalog_package_id',
        'catalog_composition_id',
        'gtin',
        'manual_ingredients',
      ]) {
        expect(payload, contains(key));
        expect(payload[key], isNull);
      }
      expect(payload['gtin_link_shared'], isFalse);
      expect(payload.containsKey('gtin_link_consent_version'), isFalse);
    });

    test('a link and a manual composition are stored and sent', () async {
      await env.medications.update(
        medication,
        const MedicationDraft(
          name: 'Med A',
          catalogLink: _link,
          manualIngredients: [
            ManualIngredient(
              name: 'Synthetic',
              strengthText: '5 mg',
              substanceId: _substance,
            ),
          ],
        ),
      );

      final row = (await env.medications.find(medication))!;
      expect(row.catalogProductId, _product);
      expect(row.catalogPackageId, _package);
      expect(row.catalogCompositionId, _composition);
      expect(row.gtin, _gtin);
      final payload = await lastPayload();
      expect(payload['catalog_product_id'], _product);
      expect(payload['gtin'], _gtin);
      expect(payload['manual_ingredients'], [
        {
          'substance_id': _substance,
          'name': 'Synthetic',
          'strength_text': '5 mg',
        },
      ]);
    });

    test('invalid references are refused and nothing is written', () async {
      final before = (await env.outbox()).length;

      for (final bad in const [
        CatalogLink(gtin: '4600000000011'),
        CatalogLink(productId: 'not-a-uuid'),
      ]) {
        await expectLater(saveLinked(bad), throwsA(isA<DataException>()));
      }
      final tooMany = List.generate(
        11,
        (i) => ManualIngredient(name: 'Line $i'),
      );
      await expectLater(
        env.medications.update(
          medication,
          MedicationDraft(name: 'Med A', manualIngredients: tooMany),
        ),
        throwsA(isA<DataException>()),
      );
      expect((await env.outbox()).length, before);
    });
  });

  group('consent', () {
    test('the version rides only in the mutation of the tick', () async {
      await saveLinked(_ticked());
      final tick = await lastPayload();
      expect(tick['gtin_link_shared'], isTrue);
      expect(tick['gtin_link_consent_version'], 1);
      expect((await env.medications.find(medication))!.gtinLinkShared, isTrue);

      // An ordinary edit is built from the row, which has no version.
      final row = (await env.medications.find(medication))!;
      await env.medications.update(
        medication,
        MedicationDraft.fromRow(row).withNewStock('10'),
      );
      final edit = await lastPayload();
      expect(edit['gtin_link_shared'], isTrue);
      expect(edit.containsKey('gtin_link_consent_version'), isFalse);
      expect(edit['stock_count'], '10');
    });

    test('a form that knows nothing of the catalog keeps link and consent',
        () async {
      await saveLinked(_ticked());

      await env.medications.update(
        medication,
        const MedicationDraft(name: 'Renamed', notes: 'after meals'),
      );

      final row = (await env.medications.find(medication))!;
      expect(row.name, 'Renamed');
      expect(row.catalogProductId, _product);
      expect(row.gtin, _gtin);
      expect(row.gtinLinkShared, isTrue);
      final payload = await lastPayload();
      expect(payload['catalog_product_id'], _product);
      expect(payload['gtin_link_shared'], isTrue);
      expect(payload.containsKey('gtin_link_consent_version'), isFalse);
    });

    test('a re-link resets the consent unless it is ticked again', () async {
      await saveLinked(_ticked());

      final row = (await env.medications.find(medication))!;
      final relinked = CatalogLink(
        productId: _otherProduct,
        packageId: _package,
        gtin: _otherGtin,
        shared: row.gtinLinkShared,
      );
      await saveLinked(relinked);

      final reset = await lastPayload();
      expect(reset['catalog_product_id'], _otherProduct);
      expect(reset['gtin_link_shared'], isFalse);
      expect(reset.containsKey('gtin_link_consent_version'), isFalse);
      expect((await env.medications.find(medication))!.gtinLinkShared, isFalse);

      await saveLinked(_ticked(gtin: _otherGtin, product: _otherProduct));
      expect((await lastPayload())['gtin_link_consent_version'], 1);
    });

    test('changing only the GTIN also resets it', () async {
      await saveLinked(_ticked());

      await saveLinked(
        const CatalogLink(productId: _product, gtin: _otherGtin, shared: true),
      );

      expect((await lastPayload())['gtin_link_shared'], isFalse);
    });

    test('unlinking clears the references, keeps the text, drops consent',
        () async {
      await env.medications.update(
        medication,
        MedicationDraft(
          name: 'Med A',
          form: 'tablet',
          catalogLink: _ticked(),
        ),
      );

      await env.medications.update(
        medication,
        const MedicationDraft(
          name: 'Med A',
          form: 'tablet',
          catalogLink: CatalogLink.none(),
        ),
      );

      final row = (await env.medications.find(medication))!;
      expect(row.form, 'tablet');
      expect(row.catalogProductId, isNull);
      expect(row.gtin, isNull);
      expect(row.gtinLinkShared, isFalse);
      expect((await lastPayload())['gtin_link_shared'], isFalse);
    });

    test('a tick without a GTIN and a product is not a consent', () async {
      await saveLinked(
        const CatalogLink(productId: _product, shared: true, consentVersion: 1),
      );

      final payload = await lastPayload();
      expect(payload['gtin_link_shared'], isFalse);
      expect(payload.containsKey('gtin_link_consent_version'), isFalse);
    });

    test('a version without the flag is refused', () async {
      await expectLater(
        saveLinked(const CatalogLink(gtin: _gtin, consentVersion: 1)),
        throwsA(isA<DataException>()),
      );
    });
  });

  group('link to an existing medication (D4)', () {
    test('replaces package, product and GTIN and keeps everything else',
        () async {
      await env.medications.update(
        medication,
        MedicationDraft(
          name: 'My pills',
          notes: 'after meals',
          stockCount: '20',
          stockUnit: 'tablet',
          catalogLink: _ticked(),
        ),
      );
      final rule = dailyRule();
      final schedule = await env.schedules.create(
        medicationId: medication,
        rule: rule,
      );

      await env.medications.linkPackage(
        medication,
        const CatalogLink(
          productId: _otherProduct,
          packageId: _package,
          compositionId: _composition,
          gtin: _otherGtin,
        ),
      );

      final row = (await env.medications.find(medication))!;
      expect(row.catalogProductId, _otherProduct);
      expect(row.gtin, _otherGtin);
      expect(row.name, 'My pills');
      expect(row.notes, 'after meals');
      expect(row.stockCount, '20');
      expect(row.gtinLinkShared, isFalse, reason: 'a re-link resets consent');
      expect((await lastPayload())['gtin_link_shared'], isFalse);
      expect(await env.schedules.find(schedule), isNotNull);
      expect(
        (await env.db.select(env.db.medications).get()).length,
        1,
        reason: 'no new medication',
      );
    });

    test('the composition is replaced only when there was none', () async {
      await saveLinked(
        const CatalogLink(productId: _product, compositionId: _composition),
      );

      await env.medications.linkPackage(
        medication,
        const CatalogLink(
          productId: _otherProduct,
          compositionId: _substance,
        ),
      );

      final row = (await env.medications.find(medication))!;
      expect(row.catalogCompositionId, _composition);
      expect(row.catalogProductId, _otherProduct);
    });
  });
}
