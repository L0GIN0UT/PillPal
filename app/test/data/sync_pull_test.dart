import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/data/api/api_client.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/api/sync_api.dart';
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/data/sync/sync_engine.dart';
import 'package:pillpal/src/data/sync/sync_status.dart';

import 'fake_server.dart';
import 'sync_fixtures.dart';
import 'test_env.dart';

Json _profile(int i) =>
    {'kind': 'managed', 'display_name': 'P$i', 'timezone': 'UTC'};

class _ThrowingTokenStore implements TokenStore {
  @override
  Future<TokenPair?> read() async => throw StateError('keystore broke');

  @override
  Future<void> write(TokenPair tokens) async {}

  @override
  Future<void> clear() async {}
}

void main() {
  late TestEnv env;

  setUp(() => env = TestEnv());
  tearDown(() => env.dispose());

  List<String?> pullCursors(TestEnv e) => [
        for (final r in e.server.requests)
          if (r.path == '/v1/sync/pull') r.query['cursor'],
      ];

  test('pages until has_more is false and stores the cursor', () async {
    for (var i = 0; i < 1200; i++) {
      env.server.seed('profile', 'p-$i', data: _profile(i), key: env.clock.now);
    }

    final report = await env.engine.sync();

    expect(report.pulled, 1200);
    expect(await env.syncState.cursor(), 1200);
    expect(pullCursors(env), ['0', '500', '1000']);
    expect(await env.db.select(env.db.profiles).get(), hasLength(1200));
  });

  test('a failed page keeps the applied pages and their cursor', () async {
    for (var i = 0; i < 700; i++) {
      env.server.seed('profile', 'p-$i', data: _profile(i), key: env.clock.now);
    }
    env.server.failPullAtCursor = 500;

    final report = await env.engine.sync();

    expect(report.errorCode, 'unavailable');
    expect(env.engine.status.phase, SyncPhase.error);
    expect(await env.syncState.cursor(), 500);
    expect(await env.db.select(env.db.profiles).get(), hasLength(500));

    env.server.failPullAtCursor = null;
    await env.engine.sync();
    expect(await env.syncState.cursor(), 700);
    expect(env.engine.status.lastSuccessAt, env.clock.now);
  });

  test('several journal rows of one entity arrive as one change', () async {
    final ids = await env.seedLocal();
    await env.engine.sync();
    final before = await env.syncState.cursor();
    for (final name in ['One', 'Two', 'Three']) {
      env.clock.advance(const Duration(seconds: 1));
      env.server.seed(
        'medication',
        ids.medication,
        data: medicationOut(ids.profile, name: name),
        key: env.clock.now,
      );
    }

    final report = await env.engine.sync();

    expect(report.pulled, 1);
    expect(await env.syncState.cursor(), before + 3);
    expect((await env.medications.find(ids.medication))!.name, 'Three');
  });

  test('pulled nulls clear local fields', () async {
    final ids = await env.seedLocal();
    await env.medications.update(
      ids.medication,
      const MedicationDraft(
        name: 'Med A',
        notes: 'after meals',
        stockCount: '10',
        stockUnit: 'tablet',
        tzMode: 'fixed',
        fixedTz: 'Europe/Berlin',
      ),
    );
    await env.engine.sync();
    env.clock.advance(const Duration(seconds: 1));
    env.server.seed(
      'medication',
      ids.medication,
      data: medicationOut(ids.profile),
      key: env.clock.now,
    );

    await env.engine.sync();

    final row = (await env.medications.find(ids.medication))!;
    expect(row.notes, isNull);
    expect(row.stockCount, isNull);
    expect(row.stockUnit, isNull);
    expect(row.fixedTz, isNull);
    expect(row.tzMode, 'local');
  });

  test('tombstones delete locally, children included', () async {
    final ids = await env.seedLocal();
    await env.engine.sync();
    env.server.seed('profile', ids.profile, key: env.clock.now, deleted: true);

    await env.engine.sync();

    expect((await env.profiles.find(ids.profile))!.deletedAt, isNotNull);
    expect((await env.medications.find(ids.medication))!.deletedAt, isNotNull);
    expect((await env.schedules.find(ids.schedule))!.deletedAt, isNotNull);
  });

  test('dose events are inserted once and learn recorded_at', () async {
    final ids = await env.seedLocal();
    final id = await env.doseEvents.record(
      medicationId: ids.medication,
      type: DoseEventType.taken,
      at: env.clock.now,
    );
    await env.engine.sync();
    await env.engine.sync();

    final rows = await env.db.select(env.db.doseEvents).get();
    expect(rows, hasLength(1));
    expect(rows.single.id, id);
    expect(rows.single.recordedAt, isNotNull);
    expect(rows.single.profileId, ids.profile);
  });

  test('410 cursor_expired triggers one full resync from 0', () async {
    for (var i = 0; i < 3; i++) {
      env.server.seed('profile', 'p-$i', data: _profile(i), key: env.clock.now);
    }
    await env.engine.sync();
    final pending =
        await env.profiles.create(displayName: 'Pending', timezone: 'UTC');
    env.server.responder = (m) => {
          'entity': m['entity'],
          'id': m['id'],
          'status': 'rejected',
          'code': 'clock_skew',
          'version': null,
          'current': null,
        };
    env.server.sync.expireCursorOnce = true;
    env.server.seed('profile', 'p-3', data: _profile(3), key: env.clock.now);

    await env.engine.sync();

    expect(pullCursors(env), ['0', '3', '0']);
    expect(await env.syncState.cursor(), 4);
    final names = [
      for (final p in await env.db.select(env.db.profiles).get()) p.displayName,
    ];
    expect(names, containsAll(['P0', 'P1', 'P2', 'P3', 'Pending']));
    expect((await env.profiles.find(pending))!.deletedAt, isNull);
  });

  test('a page whose cursor does not advance is refused before applying',
      () async {
    final broken = TestEnv();
    addTearDown(broken.dispose);
    final api = ApiClient(
      httpClient: MockClient((request) async {
        final cursor = int.parse(request.url.queryParameters['cursor']!);
        return http.Response(
          jsonEncode({
            'changes': [
              {
                'seq': cursor,
                'entity': 'profile',
                'id': 'p-x',
                'op': 'upsert',
                'data': _profile(0),
                'client_updated_at': '2026-10-16T09:00:00Z',
                'updated_by_device': 'd',
                'deleted_at': null,
              },
            ],
            'next_cursor': cursor,
            'has_more': true,
          }),
          200,
        );
      }),
      config: ApiConfig(baseUrl: Uri.parse('http://api.test'), region: 'ru'),
      tokens: broken.tokens,
      deviceId: broken.syncState.deviceId,
    );
    final engine = SyncEngine(
      db: broken.db,
      api: SyncApi(api),
      tokens: broken.tokens,
      syncState: broken.syncState,
      account: broken.account,
    );
    addTearDown(engine.dispose);

    final report = await engine.sync();

    expect(report.errorCode, 'invalid_response');
    expect(await broken.db.select(broken.db.profiles).get(), isEmpty);
  });

  test('unexpected failures end in the error state', () async {
    final engine = SyncEngine(
      db: env.db,
      api: env.syncApi,
      tokens: _ThrowingTokenStore(),
      syncState: env.syncState,
      account: env.account,
    );
    addTearDown(engine.dispose);

    final report = await engine.sync();

    expect(report.errorCode, SyncEngine.unexpected);
    expect(engine.status.phase, SyncPhase.error);
  });

  test('sync is single-flight', () async {
    await env.seedLocal();
    final first = env.engine.sync();
    final second = env.engine.sync();
    expect(identical(first, second), isTrue);
    await first;
    expect(env.server.pushes, hasLength(1));
    final third = env.engine.sync();
    expect(identical(first, third), isFalse);
    await third;
  });

  test('signed out: nothing is sent', () async {
    final signedOut = TestEnv(signedIn: false);
    addTearDown(signedOut.dispose);
    await signedOut.seedLocal();
    final report = await signedOut.engine.sync();
    expect(report.signedOut, isTrue);
    expect(signedOut.server.requests, isEmpty);
    expect(signedOut.engine.status.phase, SyncPhase.idle);
  });

  test('two devices converge on last-write-wins', () async {
    final other = TestEnv(server: env.server);
    addTearDown(other.dispose);
    final ids = await env.seedLocal();
    await env.engine.sync();
    await other.engine.sync();
    expect((await other.medications.find(ids.medication))!.name, 'Med A');

    await env.medications.update(
      ids.medication,
      const MedicationDraft(name: 'Early'),
    );
    other.clock.advance(const Duration(seconds: 30));
    await other.medications.update(
      ids.medication,
      const MedicationDraft(name: 'Late'),
    );
    await other.engine.sync();
    await env.engine.sync();
    await other.engine.sync();

    expect((await env.medications.find(ids.medication))!.name, 'Late');
    expect((await other.medications.find(ids.medication))!.name, 'Late');
    expect(env.server.dataOf('medication', ids.medication)!['name'], 'Late');
  });
}
