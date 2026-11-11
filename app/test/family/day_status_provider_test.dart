import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/features/family/day_status_providers.dart';
import 'package:pillpal/src/features/family/profile_day_summary.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// The Family tab's per-profile day status over the real (in-memory) database:
// the numbers follow the tables, hidden medications never count, anonymous
// ones count by time and status only. Synthetic data. "Now" is 2026-10-16
// 06:00 UTC, which is 08:00 in the profile's zone (Europe/Berlin, UTC+2).

/// Reads [id]'s status once it satisfies [ready]; the provider is kept alive
/// by the listener meanwhile.
Future<ProfileDayStatus> _status(
  ProviderContainer container,
  String id, {
  bool Function(ProfileDayStatus status)? ready,
}) async {
  final done = Completer<ProfileDayStatus>();
  void check(ProfileDayStatus? status) {
    if (status != null && (ready?.call(status) ?? true) && !done.isCompleted) {
      done.complete(status);
    }
  }

  final subscription = container.listen<ProfileDayStatus?>(
    profileDayStatusProvider(id),
    (previous, next) => check(next),
    fireImmediately: true,
  );
  addTearDown(subscription.close);
  return done.future;
}

typedef _Env = ({TestHarness harness, ProviderContainer container, String id});

Future<_Env> _setUp({
  String role = 'viewer',
  String kind = 'self',
  DateTime? ownerLastSeenAt,
}) async {
  final harness = TestHarness();
  final container = createContainer(harness);
  await harness.seedSelfProfile();
  final id = await seedProfile(
    harness,
    role: role,
    kind: kind,
    ownerLastSeenAt: ownerLastSeenAt,
  );
  return (harness: harness, container: container, id: id);
}

void main() {
  test('counts the day of a shared medication and the next dose', () async {
    final env = await _setUp();
    await seedForeignMedication(
      env.harness,
      env.container,
      env.id,
      times: const ['08:00', '20:00'],
    );

    final status = await _status(
      env.container,
      env.id,
      ready: (status) => status.summary.total == 2,
    );

    expect(status.summary.pending, 2);
    expect(status.summary.nextDue, DateTime.utc(2026, 10, 16, 18));
    expect(status.zone, 'Europe/Berlin');
    expect(status.summary.kind, DaySummaryKind.waiting);
  });

  test('recomputes when a dose event lands in the table', () async {
    final env = await _setUp(role: 'guardian', kind: 'managed');
    final ids = await seedForeignMedication(
      env.harness,
      env.container,
      env.id,
      times: const ['08:00', '20:00'],
    );
    await _status(
      env.container,
      env.id,
      ready: (status) => status.summary.total == 2,
    );

    await env.container.read(doseEventsRepositoryProvider).recordMark(
          medicationId: ids.medication,
          type: DoseEventType.taken,
          at: env.harness.now,
          occurrence: OccurrenceRef(
            scheduleId: ids.schedule,
            localDate: LocalDate(2026, 10, 16),
            localTime: '08:00',
          ),
          isApplied: (events) => false,
        );

    final status = await _status(
      env.container,
      env.id,
      ready: (status) => status.summary.taken == 1,
    );
    expect(status.summary.pending, 1);
    expect(status.summary.total, 2);
  });

  for (final role in ['viewer', 'editor']) {
    test('a hidden medication never changes the numbers of a $role', () async {
      final env = await _setUp(role: role);
      await seedForeignMedication(env.harness, env.container, env.id);
      final before = await _status(
        env.container,
        env.id,
        ready: (status) => status.summary.total == 1,
      );

      // The server never sends one; a stray row must still not count.
      await seedForeignMedication(
        env.harness,
        env.container,
        env.id,
        privacy: 'hidden',
        times: const ['09:00', '21:00'],
      );
      // A shared one that does count, as the marker that the new rows were
      // delivered: the hidden pair arrived with it.
      await seedForeignMedication(
        env.harness,
        env.container,
        env.id,
        times: const ['22:00'],
      );
      final after = await _status(
        env.container,
        env.id,
        ready: (status) => status.summary.total == 2,
      );

      expect(before.summary.total, 1);
      expect(after.summary.total, 2);
      expect(after.summary.pending, 2);
      expect(after.summary.nextDue, DateTime.utc(2026, 10, 16, 20));
    });
  }

  for (final role in ['owner', 'guardian']) {
    test('the $role of a profile counts the medications hidden from others',
        () async {
      final env = await _setUp(role: role, kind: 'managed');
      await seedForeignMedication(
        env.harness,
        env.container,
        env.id,
        privacy: 'hidden',
        times: const ['20:00', '21:00'],
      );

      final status = await _status(
        env.container,
        env.id,
        ready: (status) => status.summary.total == 2,
      );

      expect(status.summary.pending, 2);
    });
  }

  test('an anonymous medication counts by time and status only', () async {
    final env = await _setUp();
    await seedForeignMedication(
      env.harness,
      env.container,
      env.id,
      privacy: 'anonymous',
      redacted: true,
      times: const ['08:00', '20:00'],
    );

    final status = await _status(
      env.container,
      env.id,
      ready: (status) => status.summary.total == 2,
    );

    expect(status.summary.nextDue, DateTime.utc(2026, 10, 16, 18));
  });

  test('a profile the account has no access to has no status', () async {
    final env = await _setUp();
    await seedForeignMedication(env.harness, env.container, env.id);
    final known = await _status(
      env.container,
      env.id,
      ready: (status) => status.summary.total == 1,
    );

    final subscription = env.container.listen<ProfileDayStatus?>(
      profileDayStatusProvider('nobody'),
      (previous, next) {},
    );
    addTearDown(subscription.close);
    // Let the access stream answer: a profile that is not there stays null.
    for (var turn = 0; turn < 5; turn++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(known.summary.total, 1);
    expect(subscription.read(), isNull);
  });

  group('stale data', () {
    test('the owner not syncing for a long time marks the data old', () async {
      final env = await _setUp(
        ownerLastSeenAt: testNow.subtract(const Duration(hours: 7)),
      );
      await seedForeignMedication(env.harness, env.container, env.id);

      final status = await _status(
        env.container,
        env.id,
        ready: (status) => status.summary.total == 1,
      );

      expect(status.staleAge, const Duration(hours: 7));
    });

    test('a recent owner sync is fresh', () async {
      final env = await _setUp(
        ownerLastSeenAt: testNow.subtract(const Duration(hours: 1)),
      );
      await seedForeignMedication(env.harness, env.container, env.id);

      final status = await _status(
        env.container,
        env.id,
        ready: (status) => status.summary.total == 1,
      );

      expect(status.staleAge, isNull);
    });

    test('this device not syncing for a long time marks a ward old', () async {
      final env = await _setUp(role: 'owner', kind: 'managed');
      await seedForeignMedication(env.harness, env.container, env.id);
      await env.container
          .read(syncStateStoreProvider)
          .markSynced(testNow.subtract(const Duration(hours: 9)));

      final status = await _status(
        env.container,
        env.id,
        ready: (status) => status.staleAge != null,
      );

      expect(status.staleAge, const Duration(hours: 9));
    });
  });
}
