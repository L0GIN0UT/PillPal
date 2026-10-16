import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/auth/access_claims.dart';
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/data/sync/sync_status.dart';

import 'fake_server.dart';

void main() {
  test('providers wire repositories, sync engine and status', () async {
    final server = FakeServer();
    final db = AppDatabase(NativeDatabase.memory());
    final now = DateTime.utc(2026, 10, 16, 9);
    final tokens = InMemoryTokenStore(
      TokenPair(
        accessToken: server.access,
        refreshToken: server.refresh,
        accessExpiresAt: now.add(const Duration(minutes: 15)),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        httpClientProvider.overrideWithValue(server.client),
        tokenStoreProvider.overrideWithValue(tokens),
        clockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    // A real sign-in binds the local data before storing the tokens.
    await container
        .read(accountBindingProvider)
        .bind(AccessClaims.fromToken(server.access)!);

    final statuses = <SyncStatus>[];
    container.listen(
      syncStatusProvider,
      (previous, next) => statuses.add(next),
      fireImmediately: true,
    );

    final profile = await container
        .read(profilesRepositoryProvider)
        .create(displayName: 'Demo', timezone: 'Europe/Samara');
    final medication = await container
        .read(medicationsRepositoryProvider)
        .create(profileId: profile, draft: const MedicationDraft(name: 'Med'));
    expect(container.read(schedulesRepositoryProvider), isNotNull);
    expect(container.read(doseEventsRepositoryProvider), isNotNull);
    expect(container.read(authApiProvider), isNotNull);

    final report = await container.read(syncEngineProvider).sync();
    await Future<void>.delayed(Duration.zero);

    expect(report.ok, isTrue);
    expect(report.pushed, 2);
    expect(server.dataOf('medication', medication), isNotNull);
    expect(
      statuses.map((s) => s.phase),
      [SyncPhase.idle, SyncPhase.syncing, SyncPhase.idle],
    );
    expect(container.read(syncStatusProvider).lastSuccessAt, now);
    expect(await container.read(syncStateStoreProvider).lastSyncedAt(), now);
    expect(
      await container.read(syncEngineProvider).watchPendingCount().first,
      0,
    );
  });
}
