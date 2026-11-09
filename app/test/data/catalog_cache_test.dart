import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/catalog/catalog_cache_repository.dart';
import 'package:pillpal/src/data/catalog/catalog_install_id.dart';
import 'package:pillpal/src/data/catalog/catalog_link.dart';
import 'package:pillpal/src/data/clock.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';

import 'catalog_fixtures.dart';
import 'fake_server.dart';
import 'scope_fixtures.dart';
import 'test_env.dart';

// The on-device cache of catalog cards (ADR 0015 §2): one card fetched when
// it is opened, 30-day TTL, no batch, served offline, and gone with the
// medications it belongs to.

void main() {
  late TestEnv env;
  late CatalogTraffic traffic;
  late CatalogCacheRepository cache;

  setUp(() async {
    env = await TestEnv.create();
    traffic = CatalogTraffic();
    cache = CatalogCacheRepository(
      db: env.db,
      clock: env.clock.call,
      api: catalogApi(recordingClient(traffic)),
    );
  });
  tearDown(() => env.dispose());

  Future<List<String>> cachedIds() async {
    final rows = await env.db.select(env.db.catalogCache).get();
    return [for (final row in rows) row.id]..sort();
  }

  Future<String> linkedMedication(String profile, String product) {
    return env.medications.create(
      profileId: profile,
      draft: MedicationDraft(
        name: 'Med',
        catalogLink: CatalogLink(productId: product),
      ),
    );
  }

  Future<void> openBoth() async {
    traffic.respond = (r) => jsonResponse(cardJson());
    await cache.openCard(productA);
    traffic.respond = (r) => jsonResponse(cardJson(productId: productB));
    await cache.openCard(productB);
  }

  group('opening a card', () {
    test('is fetched once, then served from the cache', () async {
      final first = await cache.openCard(productA);
      final second = await cache.openCard(productA);

      expect(first!.product.id, productA);
      expect(second!.product.name, 'Synthetic Tablet');
      expect(traffic.requests, hasLength(1));
      expect(jsonDecode(traffic.requests.single.body), {'id': productA});
      expect(await cachedIds(), [productA]);
    });

    test('older than 30 days is fetched again', () async {
      await cache.openCard(productA);

      env.clock.advance(CatalogPolicy.cardTtl - const Duration(minutes: 1));
      await cache.openCard(productA);
      expect(traffic.requests, hasLength(1), reason: 'still fresh');

      env.clock.advance(const Duration(minutes: 2));
      await cache.openCard(productA);
      expect(traffic.requests, hasLength(2));
    });

    test('only the opened card is requested: there is no batch', () async {
      await linkedMedication(
        (await env.seedLocal()).profile,
        productB,
      );

      await cache.openCard(productA);

      expect(traffic.requests, hasLength(1));
      expect(await cachedIds(), [productA]);
    });

    test('offline, the cached card is served even when it is stale', () async {
      await cache.openCard(productA);
      env.clock.advance(const Duration(days: 90));
      traffic.respond = (r) => throw http.ClientException('offline');

      final card = await cache.openCard(productA);

      expect(card!.product.id, productA);
    });

    test('offline with nothing cached fails with network_error', () async {
      traffic.respond = (r) => throw http.ClientException('offline');

      try {
        await cache.openCard(productA);
        fail('expected an ApiException');
      } on ApiException catch (error) {
        expect(error.code, ApiException.networkError);
      }
    });

    test('without a configured catalog only the cache is read', () async {
      await cache.openCard(productA);
      final offlineOnly = CatalogCacheRepository(
        db: env.db,
        clock: env.clock.call,
      );
      env.clock.advance(const Duration(days: 90));

      expect(await offlineOnly.openCard(productA), isNotNull);
      expect(await offlineOnly.openCard(productB), isNull);
      expect(traffic.requests, hasLength(1));
    });

    test('cardsOf reads the cache and never the network', () async {
      await openBoth();
      final before = traffic.requests.length;

      final cards = await cache.cardsOf([productA, productB, 'unknown-id']);

      expect(cards.keys.toSet(), {productA, productB});
      expect(traffic.requests, hasLength(before));
    });

    test('an unreadable cached card is a miss and is fetched again', () async {
      await env.db.into(env.db.catalogCache).insert(
            CatalogCacheRow(
              kind: catalogKindProduct,
              id: productA,
              json: '{"broken":',
              fetchedAt: env.clock.now.microsecondsSinceEpoch,
            ),
          );

      final card = await cache.openCard(productA);

      expect(card!.product.id, productA);
      expect(traffic.requests, hasLength(1));
    });
  });

  group('lifecycle', () {
    test('wipeAccountData clears the cache and the install id', () async {
      final installId = CatalogInstallId(
        db: env.db,
        syncState: env.syncState,
        newId: newUuid,
        clock: env.clock.call,
      );
      final before = await installId.current();
      await openBoth();

      await env.db.wipeAccountData();

      expect(await cachedIds(), isEmpty);
      expect(await installId.current(), isNot(before));
    });

    test('signing out wipes the cache', () async {
      await openBoth();

      await env.account.signedOut();

      expect(await cachedIds(), isEmpty);
    });

    test('evicting a scope drops the cards only that scope used', () async {
      final own = (await env.seedLocal()).profile;
      final other = await env.profiles.create(
        displayName: 'Other',
        timezone: 'Europe/Berlin',
      );
      await linkedMedication(own, productA);
      await linkedMedication(other, productA);
      await linkedMedication(other, productB);
      await openBoth();

      await env.db.evictScope(other);

      expect(await cachedIds(), [productA]);
    });

    test('a revoked relative scope evicts its cards', () async {
      final ids = seedRelative(env);
      await env.engine.sync();
      final update = env.db.update(env.db.medications)
        ..where((row) => row.id.equals(ids.medication));
      const change = MedicationsCompanion(catalogProductId: Value(productB));
      await update.write(change);
      await openBoth();

      env.server.sync.revoke(ids.profile, FakeServer.defaultUserId);
      await env.engine.sync();

      expect(await cachedIds(), isEmpty);
    });

    test('deleting a medication evicts a card nobody else uses', () async {
      final profile = (await env.seedLocal()).profile;
      final kept = await linkedMedication(profile, productA);
      final gone = await linkedMedication(profile, productB);
      await openBoth();

      await env.medications.delete(gone);
      expect(await cachedIds(), [productA]);

      await env.medications.delete(kept);
      expect(await cachedIds(), isEmpty);
    });

    test('unlinking or re-linking evicts the old product', () async {
      final profile = (await env.seedLocal()).profile;
      final id = await linkedMedication(profile, productA);
      await openBoth();
      await linkedMedication(profile, productB);

      await env.medications.update(
        id,
        const MedicationDraft(name: 'Med', catalogLink: CatalogLink.none()),
      );

      expect(await cachedIds(), [productB]);
    });
  });

  group('install id', () {
    late CatalogInstallId installId;
    var counter = 0;

    setUp(() {
      counter = 0;
      installId = CatalogInstallId(
        db: env.db,
        syncState: env.syncState,
        newId: () => 'install-${++counter}',
        clock: env.clock.call,
      );
    });

    test('is stable within its lifetime', () async {
      final first = await installId.current();

      env.clock.advance(const Duration(days: 29));

      expect(await installId.current(), first);
    });

    test('is replaced every 30 days', () async {
      final first = await installId.current();

      env.clock.advance(CatalogPolicy.installIdLifetime);

      expect(await installId.current(), isNot(first));
    });

    test('is never the backend device id', () async {
      final deviceId = await env.syncState.deviceId();

      expect(await installId.current(), isNot(deviceId));
    });
  });
}
