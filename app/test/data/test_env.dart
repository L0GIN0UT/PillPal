import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:pillpal/src/data/api/api_client.dart';
import 'package:pillpal/src/data/api/auth_api.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/api/sync_api.dart';
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
  TestEnv({bool signedIn = true, FakeServer? server})
      : db = AppDatabase(NativeDatabase.memory()),
        server = server ?? FakeServer(),
        clock = FakeClock(DateTime.utc(2026, 10, 16, 9)),
        tokens = InMemoryTokenStore() {
    if (signedIn) {
      tokens = InMemoryTokenStore(
        TokenPair(
          accessToken: this.server.access,
          refreshToken: this.server.refresh,
          accessExpiresAt: clock.now.add(const Duration(minutes: 15)),
        ),
      );
    }
    syncState = SyncStateStore(db, newUuid);
    writer = LocalWriter(
      db: db,
      syncState: syncState,
      clock: clock.call,
      newId: newUuid,
    );
    api = ApiClient(
      httpClient: this.server.client,
      config: ApiConfig(baseUrl: Uri.parse('http://api.test'), region: 'ru'),
      tokens: tokens,
      deviceId: syncState.deviceId,
      clock: clock.call,
    );
    syncApi = SyncApi(api);
    authApi = AuthApi(api, tokens);
    engine = SyncEngine(
      db: db,
      api: syncApi,
      tokens: tokens,
      syncState: syncState,
      clock: clock.call,
    );
  }

  final AppDatabase db;
  final FakeServer server;
  final FakeClock clock;
  TokenStore tokens;
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
