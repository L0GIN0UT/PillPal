import 'package:drift/drift.dart' show OrderingTerm, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:pillpal/src/data/api/api_client.dart';
import 'package:pillpal/src/data/api/auth_api.dart';
import 'package:pillpal/src/data/api/sync_api.dart';
import 'package:pillpal/src/data/auth/account_binding.dart';
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/data/clock.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/db/sync_state_store.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/local_writer.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/data/repositories/profiles_repository.dart';
import 'package:pillpal/src/data/repositories/schedules_repository.dart';
import 'package:pillpal/src/data/sync/sync_engine.dart';

import 'fake_server.dart';

/// A controllable clock (UTC).
class FakeClock {
  FakeClock(this.now);

  DateTime now;

  DateTime call() => now;

  void advance(Duration duration) {
    now = now.add(duration);
  }
}

/// A daily rule with one slot (docs/spec/schedule.md).
Map<String, Object?> dailyRule({String time = '08:00'}) => {
      'v': 1,
      'kind': 'daily',
      'start_date': '2026-10-01',
      'end_date': null,
      'times': [
        {
          'time': time,
          'dose': {'amount': '1', 'unit': 'tablet'},
        },
      ],
    };

/// The data layer over an in-memory database and a [FakeServer].
class TestEnv {
  /// A device; [server] (default: a new one on this device's clock) may be
  /// shared to emulate several devices. Signed in as the server's default
  /// account, stored the way a real sign-in stores it (bound first).
  static Future<TestEnv> create({
    bool signedIn = true,
    FakeServer? server,
  }) async {
    final clock = FakeClock(DateTime.utc(2026, 10, 16, 9));
    final env = TestEnv._(clock, server ?? FakeServer(now: clock.call));
    if (signedIn) {
      await env.api
          .saveTokens(env.server.issueTokens(FakeServer.defaultUserId));
    }
    return env;
  }

  TestEnv._(this.clock, this.server) : db = _openDatabase() {
    tokens = InMemoryTokenStore();
    serverClock = ServerClock(clock.call);
    syncState = SyncStateStore(db, newUuid);
    account = AccountBinding(db, syncState);
    writer = LocalWriter(
      db: db,
      syncState: syncState,
      clock: serverClock.now,
      newId: newUuid,
    );
    api = ApiClient(
      httpClient: server.client,
      config: ApiConfig(baseUrl: Uri.parse('http://api.test'), region: 'ru'),
      tokens: tokens,
      deviceId: syncState.deviceId,
      serverClock: serverClock,
      session: account,
    );
    syncApi = SyncApi(api);
    engine = SyncEngine(
      db: db,
      api: syncApi,
      tokens: tokens,
      syncState: syncState,
      serverClock: serverClock,
    );
    authApi = AuthApi(api, tokens, flush: engine.flush);
  }

  static AppDatabase _openDatabase() {
    // Every test opens its own in-memory database on purpose.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    return AppDatabase(NativeDatabase.memory());
  }

  final AppDatabase db;
  final FakeServer server;
  final FakeClock clock;
  late final TokenStore tokens;
  late final ServerClock serverClock;
  late final AccountBinding account;
  late final SyncStateStore syncState;
  late final LocalWriter writer;
  late final ApiClient api;
  late final SyncApi syncApi;
  late final AuthApi authApi;
  late final SyncEngine engine;

  ProfilesRepository get profiles => ProfilesRepository(writer);
  MedicationsRepository get medications => MedicationsRepository(writer);
  SchedulesRepository get schedules => SchedulesRepository(writer);
  DoseEventsRepository get doseEvents => DoseEventsRepository(writer);

  /// All outbox entries in push order.
  Future<List<OutboxEntry>> outbox() =>
      (db.select(db.outbox)..orderBy([(row) => OrderingTerm.asc(row.seq)]))
          .get();

  /// Creates profile -> medication -> schedule locally; returns their ids.
  Future<({String profile, String medication, String schedule})>
      seedLocal() async {
    final profile =
        await profiles.create(displayName: 'Test', timezone: 'Europe/Samara');
    final medication = await medications.create(
      profileId: profile,
      draft: const MedicationDraft(name: 'Med A'),
    );
    final schedule =
        await schedules.create(medicationId: medication, rule: dailyRule());
    return (profile: profile, medication: medication, schedule: schedule);
  }

  Future<void> dispose() async {
    await engine.dispose();
    await db.close();
  }
}
