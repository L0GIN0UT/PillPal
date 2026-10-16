import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'api/api_client.dart';
import 'api/auth_api.dart';
import 'api/sync_api.dart';
import 'auth/account_binding.dart';
import 'auth/token_store.dart';
import 'clock.dart';
import 'config.dart';
import 'db/database.dart';
import 'db/sync_state_store.dart';
import 'repositories/dose_events_repository.dart';
import 'repositories/local_writer.dart';
import 'repositories/medications_repository.dart';
import 'repositories/profiles_repository.dart';
import 'repositories/schedules_repository.dart';
import 'sync/sync_engine.dart';
import 'sync/sync_status.dart';

// Data-layer wiring. Tests override [databaseProvider] (in-memory drift),
// [httpClientProvider] (MockClient), [tokenStoreProvider], [clockProvider]
// and [idGeneratorProvider].

/// Current time (UTC).
final clockProvider = Provider<Clock>((ref) => systemClock);

/// Device clock corrected by the server's `Date` (for conflict keys).
final serverClockProvider = Provider<ServerClock>(
  (ref) => ServerClock(ref.watch(clockProvider)),
);

/// Entity id generator (lowercase UUID v4).
final idGeneratorProvider = Provider<IdGenerator>((ref) => newUuid);

/// Backend URL and region from `--dart-define`.
final apiConfigProvider = Provider<ApiConfig>(
  (ref) => ApiConfig.fromEnvironment(),
);

/// The local database.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase.open();
  ref.onDispose(() => unawaited(db.close()));
  return db;
});

/// HTTP client.
final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Device id, pull cursor, account binding and last sync time.
final syncStateStoreProvider = Provider<SyncStateStore>(
  (ref) => SyncStateStore(
    ref.watch(databaseProvider),
    ref.watch(idGeneratorProvider),
  ),
);

/// Session token storage (platform keystore, cleared on a new install).
final tokenStoreProvider = Provider<TokenStore>(
  (ref) => SecureTokenStore(
    isFreshInstall: ref.watch(syncStateStoreProvider).claimSecureStorageReset,
  ),
);

/// Binds local data to the signed-in account; erases it on sign-out.
final accountBindingProvider = Provider<AccountBinding>(
  (ref) => AccountBinding(
    ref.watch(databaseProvider),
    ref.watch(syncStateStoreProvider),
  ),
);

/// HTTP transport with auth and token refresh.
final apiClientProvider = Provider<ApiClient>((ref) {
  final syncState = ref.watch(syncStateStoreProvider);
  return ApiClient(
    httpClient: ref.watch(httpClientProvider),
    config: ref.watch(apiConfigProvider),
    tokens: ref.watch(tokenStoreProvider),
    deviceId: syncState.deviceId,
    serverClock: ref.watch(serverClockProvider),
    session: ref.watch(accountBindingProvider),
  );
});

/// Registration, verification, login and logout (flushes the outbox first).
final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(
    ref.watch(apiClientProvider),
    ref.watch(tokenStoreProvider),
    flush: ref.watch(syncEngineProvider).flush,
  ),
);

/// Sync push/pull endpoints.
final syncApiProvider = Provider<SyncApi>(
  (ref) => SyncApi(ref.watch(apiClientProvider)),
);

final _localWriterProvider = Provider<LocalWriter>(
  (ref) => LocalWriter(
    db: ref.watch(databaseProvider),
    syncState: ref.watch(syncStateStoreProvider),
    clock: ref.watch(serverClockProvider).now,
    newId: ref.watch(idGeneratorProvider),
  ),
);

/// Profiles.
final profilesRepositoryProvider = Provider<ProfilesRepository>(
  (ref) => ProfilesRepository(ref.watch(_localWriterProvider)),
);

/// Medications.
final medicationsRepositoryProvider = Provider<MedicationsRepository>(
  (ref) => MedicationsRepository(ref.watch(_localWriterProvider)),
);

/// Schedules.
final schedulesRepositoryProvider = Provider<SchedulesRepository>(
  (ref) => SchedulesRepository(ref.watch(_localWriterProvider)),
);

/// Dose events.
final doseEventsRepositoryProvider = Provider<DoseEventsRepository>(
  (ref) => DoseEventsRepository(ref.watch(_localWriterProvider)),
);

/// The sync engine; call `sync()` on start, resume, after writes and on
/// connectivity changes (2.2/2.3 wire the triggers).
final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(
    db: ref.watch(databaseProvider),
    api: ref.watch(syncApiProvider),
    tokens: ref.watch(tokenStoreProvider),
    syncState: ref.watch(syncStateStoreProvider),
    account: ref.watch(accountBindingProvider),
    serverClock: ref.watch(serverClockProvider),
  );
  ref.onDispose(() => unawaited(engine.dispose()));
  return engine;
});

/// Sync status for the UI (idle / syncing / error + last success).
final syncStatusProvider = NotifierProvider<SyncStatusNotifier, SyncStatus>(
  SyncStatusNotifier.new,
);

/// Mirrors [SyncEngine.statusChanges].
class SyncStatusNotifier extends Notifier<SyncStatus> {
  @override
  SyncStatus build() {
    final engine = ref.watch(syncEngineProvider);
    final subscription = engine.statusChanges.listen((status) {
      state = status;
    });
    ref.onDispose(() => unawaited(subscription.cancel()));
    return engine.status;
  }
}
