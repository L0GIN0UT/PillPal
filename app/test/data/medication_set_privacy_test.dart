import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/catalog/catalog_link.dart';
import 'package:pillpal/src/data/catalog/manual_ingredient.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';

import 'test_env.dart';

// D4 (docs/redesign-plan.md): the relative screen changes only the privacy
// level, from the row as stored now: one outbox entry, nothing else moves.

const String _product = '5b0f4a52-8e1b-4f60-9d3b-0a2f3c9d1e11';
const String _package = '7d2b6c74-0a3d-4b82-9f5d-2c4b5e1f3a33';
const String _gtin = '04607000000007';

void main() {
  late TestEnv env;
  late MedicationsRepository meds;
  late String medication;

  setUp(() async {
    env = await TestEnv.create();
    meds = MedicationsRepository(
      env.writer,
      contributionsEnabled: () async => true,
    );
    medication = (await env.seedLocal()).medication;
    await meds.update(
      medication,
      MedicationDraft(
        name: 'Med A',
        tzMode: 'fixed',
        fixedTz: 'Asia/Tokyo',
        stockCount: '12',
        stockUnit: 'tablet',
        lowStockDays: 5,
        stockSetAt: DateTime.utc(2026, 10, 1, 8),
        catalogLink: const CatalogLink(
          productId: _product,
          packageId: _package,
          gtin: _gtin,
          shared: true,
          consentVersion: 1,
        ),
        manualIngredients: const [ManualIngredient(name: 'Synthetic')],
      ),
    );
  });
  tearDown(() => env.dispose());

  test('only the privacy changes; link, consent and stock stay', () async {
    final before = (await meds.find(medication))!;
    final entries = (await env.outbox()).length;

    await meds.setPrivacy(medication, 'hidden');

    final after = (await meds.find(medication))!;
    expect(after.privacy, 'hidden');
    expect(
      after.copyWith(
        privacy: before.privacy,
        clientUpdatedAt: before.clientUpdatedAt,
        updatedByDevice: before.updatedByDevice,
      ),
      before,
    );
    expect(after.gtinLinkShared, isTrue);
    expect(after.stockSetAt, before.stockSetAt);
    final all = await env.outbox();
    // The consent grant rode in an earlier entry; this one carries none.
    expect(all.length, entries + 1);
    final payload = jsonDecode(all.last.payload!) as Map<String, Object?>;
    expect(payload['privacy'], 'hidden');
    expect(payload['gtin_link_shared'], isTrue);
    expect(payload.containsKey('gtin_link_consent_version'), isFalse);
  });

  test('a rename and a refill that landed meanwhile are kept', () async {
    await meds.update(
      medication,
      const MedicationDraft(
        name: 'Renamed',
        stockCount: '30',
        stockUnit: 'tablet',
      ),
    );
    final landed = (await meds.find(medication))!;

    await meds.setPrivacy(medication, 'anonymous');

    final after = (await meds.find(medication))!;
    expect(after.name, 'Renamed');
    expect(after.stockCount, landed.stockCount);
    expect(after.stockSetAt, landed.stockSetAt);
    expect(after.privacy, 'anonymous');
  });

  test('withPrivacy changes the level and nothing else', () {
    final draft = MedicationDraft(
      name: 'Med A',
      form: 'tablet',
      strengthText: '10 mg',
      notes: 'n',
      tzMode: 'fixed',
      fixedTz: 'Asia/Tokyo',
      stockCount: '12',
      stockUnit: 'tablet',
      lowStockDays: 5,
      stockSetAt: DateTime.utc(2026, 10, 1),
      keepStock: true,
      catalogLink: const CatalogLink.none(),
      manualIngredients: const [ManualIngredient(name: 'Synthetic')],
    );

    final changed = draft.withPrivacy('hidden');

    expect(changed.privacy, 'hidden');
    expect(draft.privacy, 'shared');
    expect(changed.name, draft.name);
    expect(changed.form, draft.form);
    expect(changed.strengthText, draft.strengthText);
    expect(changed.notes, draft.notes);
    expect(changed.tzMode, draft.tzMode);
    expect(changed.fixedTz, draft.fixedTz);
    expect(changed.stockCount, draft.stockCount);
    expect(changed.stockUnit, draft.stockUnit);
    expect(changed.lowStockDays, draft.lowStockDays);
    expect(changed.stockSetAt, draft.stockSetAt);
    expect(changed.keepStock, isTrue);
    expect(changed.catalogLink, same(draft.catalogLink));
    expect(changed.manualIngredients, draft.manualIngredients);
  });
}
