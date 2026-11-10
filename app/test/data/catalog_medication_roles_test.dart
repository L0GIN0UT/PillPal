import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/catalog/catalog_link.dart';
import 'package:pillpal/src/data/catalog/manual_ingredient.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/data/sync/server_rows.dart';

import 'scope_fixtures.dart';
import 'test_env.dart';

// Catalog references of the medications of other people and of pulled rows
// (ADR 0015 §4): editors never carry the consent, a pull never brings back
// the write-only version, a redacted row has none of the fields.

const String _product = '5b0f4a52-8e1b-4f60-9d3b-0a2f3c9d1e11';
const String _package = '7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a33';
const String _composition = '8e3c7d85-1b4e-4c93-8a6e-3d5c6f2a4b44';
const String _gtin = '04607000000007';

const Map<String, Object?> _syntheticLine = {
  'substance_id': null,
  'name': 'Synthetic',
  'strength_text': null,
};

const CatalogLink _ticked = CatalogLink(
  productId: _product,
  packageId: _package,
  gtin: _gtin,
  shared: true,
  consentVersion: 1,
);

void main() {
  late TestEnv env;
  late MedicationsRepository meds;
  late String profile;
  late String medication;

  setUp(() async {
    env = await TestEnv.create();
    meds = MedicationsRepository(
      env.writer,
      contributionsEnabled: () async => true,
    );
    final ids = await env.seedLocal();
    profile = ids.profile;
    medication = ids.medication;
  });
  tearDown(() => env.dispose());

  Future<Map<String, Object?>> lastPayload() async {
    final entry = (await env.outbox()).last;
    return jsonDecode(entry.payload!) as Map<String, Object?>;
  }

  Future<void> saveLinked(CatalogLink link) {
    final draft = MedicationDraft(name: 'Med A', catalogLink: link);
    return meds.update(medication, draft);
  }

  group('roles without full access', () {
    test('an editor never sends the flag or the version', () async {
      final ids = seedRelative(env, role: 'editor');
      await env.engine.sync();
      final before = (await env.outbox()).length;

      await meds.update(
        ids.medication,
        const MedicationDraft(name: 'Edited', catalogLink: _ticked),
      );

      final entries = await env.outbox();
      expect(entries.length, before + 1);
      final payload = jsonDecode(entries.last.payload!) as Map<String, Object?>;
      expect(payload['catalog_product_id'], _product);
      expect(payload.containsKey('gtin_link_shared'), isFalse);
      expect(payload.containsKey('gtin_link_consent_version'), isFalse);
      final row = (await meds.find(ids.medication))!;
      expect(row.gtinLinkShared, isFalse);
    });

    test('without a scope row the stored consent is kept, not sent', () async {
      await saveLinked(_ticked);
      await env.db.delete(env.db.accessScopes).go();

      await meds.update(medication, const MedicationDraft(name: 'Renamed'));

      final row = (await meds.find(medication))!;
      expect(row.name, 'Renamed');
      expect(row.gtinLinkShared, isTrue);
      expect((await lastPayload()).containsKey('gtin_link_shared'), isFalse);
    });

    test('an own medication of a profile without a scope row sends no flag',
        () async {
      await env.db.delete(env.db.accessScopes).go();

      await saveLinked(_ticked);

      final payload = await lastPayload();
      expect(payload.containsKey('gtin_link_shared'), isFalse);
    });
  });

  group('pulled rows', () {
    const key = RowKey(1, 'dev');

    Map<String, Object?> pulled({Map<String, Object?> extra = const {}}) {
      return {
        'profile_id': profile,
        'name': 'Pulled',
        'tz_mode': 'local',
        'privacy': 'shared',
        ...extra,
      };
    }

    test('a full row keeps the references and the consent flag', () {
      final row = medicationRow(
        'm',
        pulled(
          extra: {
            'catalog_product_id': _product,
            'gtin': _gtin,
            'manual_ingredients': [
              _syntheticLine,
            ],
            'gtin_link_shared': true,
            'gtin_link_consented_at': '2026-11-09T10:00:00Z',
          },
        ),
        key,
      );

      expect(row.catalogProductId, _product);
      expect(row.gtin, _gtin);
      expect(row.gtinLinkShared, isTrue);
      expect(
        ManualIngredient.decode(row.manualIngredients).single.name,
        'Synthetic',
      );
    });

    test('a projected row has no flag: it reads as false', () {
      final row = medicationRow(
        'm',
        pulled(extra: {'catalog_product_id': _product}),
        key,
      );

      expect(row.catalogProductId, _product);
      expect(row.gtinLinkShared, isFalse);
    });

    test('a redacted row carries none of the fields', () {
      final row = medicationRow(
        'm',
        pulled(
          extra: {
            'redacted': true,
            'catalog_product_id': _product,
            'catalog_package_id': _package,
            'catalog_composition_id': _composition,
            'gtin': _gtin,
            'manual_ingredients': [
              _syntheticLine,
            ],
            'gtin_link_shared': true,
          },
        ),
        key,
      );

      expect(row.name, isNull);
      expect(row.catalogProductId, isNull);
      expect(row.catalogPackageId, isNull);
      expect(row.catalogCompositionId, isNull);
      expect(row.gtin, isNull);
      expect(row.manualIngredients, isNull);
      expect(row.gtinLinkShared, isFalse);
    });

    test('the write-only consent version is never brought back', () async {
      final row = medicationRow(
        medication,
        pulled(
          extra: {
            'catalog_product_id': _product,
            'gtin': _gtin,
            'gtin_link_shared': true,
            'gtin_link_consent_version': 3,
          },
        ),
        key,
      );
      await env.db.into(env.db.medications).insertOnConflictUpdate(row);

      await meds.update(
        medication,
        MedicationDraft.fromRow(row).withNewStock('5'),
      );

      final payload = await lastPayload();
      expect(payload['gtin_link_shared'], isTrue);
      expect(payload.containsKey('gtin_link_consent_version'), isFalse);
    });
  });
}
