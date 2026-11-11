import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'api/api_client.dart';
import 'api/api_exception.dart';
import 'api/auth_api.dart';
import 'api/consents_api.dart';
import 'api/relatives_api.dart';
import 'api/sync_api.dart';
import 'auth/access_claims.dart';
import 'auth/account_binding.dart';
import 'auth/token_store.dart';
import 'catalog/catalog_api.dart';
import 'catalog/catalog_cache_repository.dart';
import 'catalog/catalog_install_id.dart';
import 'clock.dart';
import 'config.dart';
import 'db/database.dart';
import 'db/sync_state_store.dart';
import 'repositories/access_repository.dart';
import 'repositories/dose_events_repository.dart';
import 'repositories/local_writer.dart';
import 'repositories/medications_repository.dart';
import 'repositories/profiles_repository.dart';
import 'repositories/relatives_repository.dart';
import 'repositories/schedules_repository.dart';
import 'sync/medical_sync_gate.dart';
import 'sync/sync_engine.dart';
import 'sync/sync_lease.dart';
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

/// The lease that serializes push and token refresh with the background
/// engines (ADR 0001 addendum 3.7). It compares device-clock instants: all
/// holders run on this device.
final syncLeaseProvider = Provider<SyncLease>(
  (ref) => SyncLease(
    db: ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
    newId: ref.watch(idGeneratorProvider),
  ),
);

/// Told by the API client when a session starts or ends. The app overrides
/// it to also clear reminders (`reminderAppOverrides`); by default it is the
/// [AccountBinding].
final sessionListenerProvider = Provider<SessionListener>(
  (ref) => ref.watch(accountBindingProvider),
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
    session: ref.watch(sessionListenerProvider),
    lease: ref.watch(syncLeaseProvider),
  );
});

/// What runs at sign-out while the session still works (the push token is
/// deleted here). Nothing by default; `main.dart` overrides it.
final beforeLogoutProvider = Provider<Future<void> Function()?>((ref) => null);

/// Registration, verification, login and logout (flushes the outbox first).
final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(
    ref.watch(apiClientProvider),
    ref.watch(tokenStoreProvider),
    flush: ref.watch(syncEngineProvider).flush,
    beforeLogout: ref.watch(beforeLogoutProvider),
  ),
);

/// Sync push/pull endpoints.
final syncApiProvider = Provider<SyncApi>(
  (ref) => SyncApi(ref.watch(apiClientProvider)),
);

/// The consent records and the versions still missing (ADR 0016).
final consentsApiProvider = Provider<ConsentsApi>(
  (ref) => ConsentsApi(ref.watch(apiClientProvider)),
);

/// Pauses the medical sync while the consent for health data is missing.
final medicalSyncGateProvider = Provider<MedicalSyncGate>(
  (ref) => ConsentSyncGate(
    syncState: ref.watch(syncStateStoreProvider),
    api: ref.watch(consentsApiProvider),
  ),
);

/// Invites, grants, features and account deletion.
final relativesApiProvider = Provider<RelativesApi>(
  (ref) => RelativesApi(ref.watch(apiClientProvider)),
);

/// The stored links to relatives (last `GET /v1/grants`).
final relativesRepositoryProvider = Provider<RelativesRepository>(
  (ref) => RelativesRepository(
    ref.watch(databaseProvider),
    ref.watch(syncStateStoreProvider),
  ),
);

final _localWriterProvider = Provider<LocalWriter>(
  (ref) => LocalWriter(
    db: ref.watch(databaseProvider),
    syncState: ref.watch(syncStateStoreProvider),
    clock: ref.watch(serverClockProvider).now,
    newId: ref.watch(idGeneratorProvider),
  ),
);

/// Scopes (profiles the account can access), roles and device settings.
final accessRepositoryProvider = Provider<AccessRepository>(
  (ref) => AccessRepository(ref.watch(databaseProvider)),
);

/// Profiles.
final profilesRepositoryProvider = Provider<ProfilesRepository>(
  (ref) => ProfilesRepository(ref.watch(_localWriterProvider)),
);

/// Medications.
final medicationsRepositoryProvider = Provider<MedicationsRepository>(
  (ref) => MedicationsRepository(
    ref.watch(_localWriterProvider),
    contributionsEnabled: () => _contributionsEnabled(ref),
  ),
);

/// `FeaturesOut.catalog_contributions_enabled`; false when it cannot be
/// asked (offline), so a consent is never recorded blind.
Future<bool> _contributionsEnabled(Ref ref) async {
  try {
    final features = await ref.read(relativesApiProvider).features();
    return features.catalogContributionsEnabled;
  } on ApiException {
    return false;
  }
}

/// Schedules.
final schedulesRepositoryProvider = Provider<SchedulesRepository>(
  (ref) => SchedulesRepository(ref.watch(_localWriterProvider)),
);

/// Dose events.
final doseEventsRepositoryProvider = Provider<DoseEventsRepository>(
  (ref) => DoseEventsRepository(ref.watch(_localWriterProvider)),
);

/// The catalog URL of this build's region; disabled without
/// `PILLPAL_CATALOG_URLS`, and then all catalog UI is hidden.
final catalogConfigProvider = Provider<CatalogConfig>(
  (ref) => CatalogConfig.fromEnvironment(
    region: ref.watch(apiConfigProvider).region,
  ),
);

/// HTTP client of the catalog, separate from [httpClientProvider] so that
/// nothing of the backend session can reach it (ADR 0015 §3).
final catalogHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// The catalog-only install id (`X-Catalog-Install`).
final catalogInstallIdProvider = Provider<CatalogInstallId>(
  (ref) => CatalogInstallId(
    db: ref.watch(databaseProvider),
    syncState: ref.watch(syncStateStoreProvider),
    newId: ref.watch(idGeneratorProvider),
    clock: ref.watch(clockProvider),
  ),
);

/// The catalog API; null when the build has no catalog.
final catalogApiProvider = Provider<CatalogApi?>((ref) {
  final config = ref.watch(catalogConfigProvider);
  if (!config.enabled) {
    return null;
  }
  return CatalogApi(
    httpClient: ref.watch(catalogHttpClientProvider),
    config: config,
    installId: ref.watch(catalogInstallIdProvider).current,
  );
});

/// The on-device cache of catalog cards.
final catalogCacheRepositoryProvider = Provider<CatalogCacheRepository>(
  (ref) => CatalogCacheRepository(
    db: ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
    api: ref.watch(catalogApiProvider),
  ),
);

/// The sync engine; call `sync()` on start, resume, after writes and on
/// connectivity changes (2.2/2.3 wire the triggers).
final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(
    db: ref.watch(databaseProvider),
    api: ref.watch(syncApiProvider),
    tokens: ref.watch(tokenStoreProvider),
    syncState: ref.watch(syncStateStoreProvider),
    gate: ref.watch(medicalSyncGateProvider),
    serverClock: ref.watch(serverClockProvider),
    lease: ref.watch(syncLeaseProvider),
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
