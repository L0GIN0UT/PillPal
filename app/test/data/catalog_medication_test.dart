import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/sync_dto.dart';
import 'package:pillpal/src/data/catalog/catalog_link.dart';
import 'package:pillpal/src/data/catalog/manual_ingredient.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/local_writer.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/data/sync/server_state_applier.dart';

import 'catalog_fixtures.dart';
import 'fake_server.dart';
import 'sync_fixtures.dart';
import 'test_env.dart';

// The medication's catalog references and the consent to count the link
// (ADR 0015 §4): what is stored and what the push carries; see
// catalog_medication_roles_test.dart for other roles and pulled rows.

const String _product = '5b0f4a52-8e1b-4f60-9d3b-0a2f3c9d1e11';
const String _otherProduct = '6c1a5b63-9f2c-4a71-8e4c-1b3a4d0e2f22';
const String _package = '7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a33';
const String _composition = '8e3c7d85-1b4e-4c93-8a6e-3d5c6f2a4b44';
const String _substance = '9f4d8e96-2c5f-4da4-9b7f-4e6d7a3b5c55';
const String _gtin = shareableGtin;
const String _otherGtin = otherShareableGtin;

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
  late MedicationsRepository meds;
  late String profile;
  late String medication;
  late String schedule;

  setUp(() async {
    env = await TestEnv.create();
    meds = MedicationsRepository(
      env.writer,
      contributionsEnabled: () async => true,
    );
    final ids = await env.seedLocal();
    profile = ids.profile;
    medication = ids.medication;
    schedule = ids.schedule;
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
      await meds.update(
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

      final row = (await meds.find(medication))!;
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
        meds.update(
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
      final entries = await env.outbox();
      final first = entries[entries.length - 2];
      final edit = jsonDecode(first.payload!) as Map<String, Object?>;
      expect(edit['gtin_link_shared'], isFalse);
      expect(edit.containsKey('gtin_link_consent_version'), isFalse);
      final tick = await lastPayload();
      expect(tick['gtin_link_shared'], isTrue);
      expect(tick['gtin_link_consent_version'], 1);
      expect(entries.last.clientUpdatedAt, first.clientUpdatedAt + 1);
      expect((await meds.find(medication))!.gtinLinkShared, isTrue);

      // An ordinary edit is built from the row, which has no version.
      final row = (await meds.find(medication))!;
      await meds.update(
        medication,
        MedicationDraft.fromRow(row).withNewStock('10'),
      );
      final later = await lastPayload();
      expect(later['gtin_link_shared'], isTrue);
      expect(later.containsKey('gtin_link_consent_version'), isFalse);
      expect(later['stock_count'], '10');
    });

    test('the same pair linked again keeps the stored consent', () async {
      await saveLinked(_ticked());

      await meds.linkPackage(
        medication,
        const CatalogLink(
          productId: _product,
          packageId: _otherProduct,
          gtin: _gtin,
        ),
      );

      final row = (await meds.find(medication))!;
      expect(row.catalogPackageId, _otherProduct);
      expect(row.gtinLinkShared, isTrue);
      final payload = await lastPayload();
      expect(payload['gtin_link_shared'], isTrue);
      expect(payload.containsKey('gtin_link_consent_version'), isFalse);
    });

    test('a refused tick writes nothing and keeps what exists', () async {
      final disabled = MedicationsRepository(env.writer);
      const restricted = CatalogLink(
        productId: _product,
        gtin: restrictedGtin,
        shared: true,
        consentVersion: 1,
      );
      const unknownVersion = CatalogLink(
        productId: _product,
        gtin: _gtin,
        shared: true,
        consentVersion: 2,
      );
      final before = (await env.outbox()).length;

      final refusal = throwsA(isA<DataException>());

      await expectLater(
        disabled.create(
          profileId: profile,
          draft: MedicationDraft(name: 'New', catalogLink: _ticked()),
        ),
        refusal,
      );
      await expectLater(
        disabled.update(
          medication,
          MedicationDraft(name: 'Med A', catalogLink: _ticked()),
        ),
        refusal,
      );
      await expectLater(
        meds.create(
          profileId: profile,
          draft: const MedicationDraft(name: 'New', catalogLink: restricted),
        ),
        refusal,
      );
      await expectLater(
        meds.update(
          medication,
          const MedicationDraft(name: 'Med A', catalogLink: unknownVersion),
        ),
        refusal,
      );
      expect((await env.outbox()).length, before);
      expect(await env.db.select(env.db.medications).get(), hasLength(1));
      expect((await meds.find(medication))!.catalogProductId, isNull);
      expect(await env.schedules.find(schedule), isNotNull);
    });

    test('a form that knows nothing of the catalog keeps link and consent',
        () async {
      await saveLinked(_ticked());

      await meds.update(
        medication,
        const MedicationDraft(name: 'Renamed', notes: 'after meals'),
      );

      final row = (await meds.find(medication))!;
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

      final row = (await meds.find(medication))!;
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
      expect((await meds.find(medication))!.gtinLinkShared, isFalse);

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
      await meds.update(
        medication,
        MedicationDraft(
          name: 'Med A',
          form: 'tablet',
          catalogLink: _ticked(),
        ),
      );

      await meds.update(
        medication,
        const MedicationDraft(
          name: 'Med A',
          form: 'tablet',
          catalogLink: CatalogLink.none(),
        ),
      );

      final row = (await meds.find(medication))!;
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

  group('a grant on the wire', () {
    Map<String, Object?> dataOf(Map<String, Object?> mutation) {
      return mutation['data']! as Map<String, Object?>;
    }

    Future<String> createTicked() {
      return meds.create(
        profileId: profile,
        draft: MedicationDraft(name: 'New', catalogLink: _ticked()),
      );
    }

    List<Map<String, Object?>> sentFor(String id) {
      return [
        for (final batch in env.server.pushes)
          for (final mutation in batch)
            if (mutation['id'] == id) mutation,
      ];
    }

    test('only the follow-up entry carries the version', () async {
      final id = await createTicked();

      await env.engine.sync();

      final sent = sentFor(id);
      expect(sent, hasLength(2));
      final edit = dataOf(sent.first);
      final grant = dataOf(sent.last);
      expect(edit['gtin_link_shared'], isFalse);
      expect(edit.containsKey('gtin_link_consent_version'), isFalse);
      expect(grant['gtin_link_shared'], isTrue);
      expect(grant['gtin_link_consent_version'], 1);
      expect(await env.outbox(), isEmpty);
    });

    test('a refused grant parks only itself, the create and schedule stay',
        () async {
      final id = await createTicked();
      final extra = await env.schedules.create(
        medicationId: id,
        rule: dailyRule(),
      );
      env.server.responder = (m) {
        final data = m['data'];
        final grant = data is Map<String, Object?> &&
            data.containsKey('gtin_link_consent_version');
        return grant ? rejected(m, 'gtin_not_shareable') : null;
      };

      await env.engine.sync();

      final row = (await meds.find(id))!;
      expect(row.deletedAt, isNull);
      expect(row.catalogProductId, _product);
      expect(row.gtinLinkShared, isFalse);
      expect((await env.schedules.find(extra))!.deletedAt, isNull);
      expect(env.server.dataOf('medication', id), isNotNull);
      final parked = (await env.outbox()).where((e) => e.parked).toList();
      expect(parked, hasLength(1));
      expect(parked.single.lastError, 'gtin_not_shareable');
    });

    test('a clock skew drops the version of a re-keyed grant', () async {
      final serverTime = FakeClock(DateTime.utc(2026, 10, 16, 9));
      final skewed = await TestEnv.create(
        server: FakeServer(now: serverTime.call),
      );
      addTearDown(skewed.dispose);
      skewed.clock.advance(const Duration(hours: 1));
      final ids = await skewed.seedLocal();
      final repository = MedicationsRepository(
        skewed.writer,
        contributionsEnabled: () async => true,
      );
      final id = await repository.create(
        profileId: ids.profile,
        draft: MedicationDraft(name: 'New', catalogLink: _ticked()),
      );

      final report = await skewed.engine.sync();

      expect(report.ok, isTrue);
      final sent = [
        for (final batch in skewed.server.pushes)
          for (final mutation in batch)
            if (mutation['id'] == id) dataOf(mutation),
      ];
      final grants = [
        for (final data in sent)
          if (data['gtin_link_shared'] == true) data,
      ];
      expect(grants.length, greaterThan(1));
      expect(grants.first['gtin_link_consent_version'], 1);
      expect(grants.last.containsKey('gtin_link_consent_version'), isFalse);
    });
  });

  group('tombstones', () {
    test('a local delete erases the references and the consent', () async {
      await meds.update(
        medication,
        MedicationDraft(name: 'Med A', catalogLink: _ticked()),
      );

      await meds.delete(medication);

      final row = (await meds.find(medication))!;
      expect(row.deletedAt, isNotNull);
      expect(row.catalogProductId, isNull);
      expect(row.catalogPackageId, isNull);
      expect(row.gtin, isNull);
      expect(row.manualIngredients, isNull);
      expect(row.gtinLinkShared, isFalse);
    });

    test('a pulled tombstone erases them too', () async {
      await saveLinked(_ticked());

      final applier = ServerStateApplier(env.db);
      await applier.markDeleted(SyncEntity.medication, medication, 5);

      final row = (await meds.find(medication))!;
      expect(row.catalogProductId, isNull);
      expect(row.gtinLinkShared, isFalse);
    });

    test('a deleted profile erases those of its medications', () async {
      await saveLinked(_ticked());

      await env.profiles.delete(profile);

      final row = (await meds.find(medication))!;
      expect(row.catalogProductId, isNull);
      expect(row.gtinLinkShared, isFalse);
    });
  });

  group('corrupt stored composition', () {
    test('surfaces a typed error instead of a crash', () async {
      final update = env.db.update(env.db.medications)
        ..where((row) => row.id.equals(medication));
      const change = MedicationsCompanion(manualIngredients: Value('not json'));
      await update.write(change);
      final row = (await meds.find(medication))!;

      expect(
        () => MedicationDraft.fromRow(row),
        throwsA(
          isA<DataException>()
              .having((e) => e.code, 'code', DataException.corruptData),
        ),
      );
      await expectLater(
        meds.setStock(medication, '5'),
        throwsA(isA<DataException>()),
      );
    });
  });

  group('link to an existing medication (D4)', () {
    test('replaces package, product and GTIN and keeps everything else',
        () async {
      await meds.update(
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

      await meds.linkPackage(
        medication,
        const CatalogLink(
          productId: _otherProduct,
          packageId: _package,
          compositionId: _composition,
          gtin: _otherGtin,
        ),
      );

      final row = (await meds.find(medication))!;
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

      await meds.linkPackage(
        medication,
        const CatalogLink(
          productId: _otherProduct,
          compositionId: _substance,
        ),
      );

      final row = (await meds.find(medication))!;
      expect(row.catalogCompositionId, _composition);
      expect(row.catalogProductId, _otherProduct);
    });
  });
}
