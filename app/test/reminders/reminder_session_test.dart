import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/auth/access_claims.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/reminders/providers.dart';
import 'package:pillpal/src/reminders/reminder_session.dart';

import 'reminder_test_env.dart';

const _accountA = AccessClaims(
  userId: '0a000000-0000-4000-8000-00000000000a',
  region: 'ru',
);
const _accountB = AccessClaims(
  userId: '0b000000-0000-4000-8000-00000000000b',
  region: 'ru',
);

void main() {
  late ReminderTestEnv env;
  late ReminderSessionListener listener;

  setUp(() async {
    env = await ReminderTestEnv.create();
    listener = ReminderSessionListener(
      binding: env.data.account,
      clearReminders: env.service.clearAll,
    );
    await listener.signingIn(_accountA);
    await env.seed();
    await env.service.replan();
    // The Oct 17 reminder fired and sits in the tray; Oct 18 and 19 are
    // pending.
    env.data.clock.now = DateTime.utc(2026, 10, 17, 4, 10);
    await env.service.replan();
    expect(env.scheduler.tray, hasLength(1));
    expect(env.scheduler.pending, hasLength(2));
  });
  tearDown(() => env.dispose());

  Future<void> expectCleared() async {
    final db = env.data.db;
    expect(env.scheduler.pending, isEmpty);
    expect(env.scheduler.tray, isEmpty);
    expect(await db.select(db.appliedNotifications).get(), isEmpty);
    expect(await db.select(db.medications).get(), isEmpty);
    expect(env.service.status.planned, 0);
  }

  test('logout cancels pending reminders and clears the tray', () async {
    await listener.signedOut();

    await expectCleared();
    // A later re-plan has nothing to schedule.
    await env.service.replan();
    expect(env.scheduler.pending, isEmpty);
  });

  test('signing in as another account clears them too', () async {
    await listener.signingIn(_accountB);

    await expectCleared();
  });

  test('the same account signing in again keeps them', () async {
    env.scheduler.clearLog();

    await listener.signingIn(_accountA);

    expect(env.scheduler.calls, isEmpty);
    expect(env.scheduler.pending, hasLength(2));
    expect(env.scheduler.tray, hasLength(1));
  });

  test('a running re-plan finishes before everything is cancelled', () async {
    env.data.clock.now = DateTime.utc(2026, 10, 17, 5);
    final replan = env.service.replan();

    await listener.signedOut();
    await replan;

    await expectCleared();
  });

  test('the app installs it as the session listener of the API client',
      () async {
    final container = ProviderContainer(
      overrides: [
        ...reminderAppOverrides,
        databaseProvider.overrideWithValue(env.data.db),
        notificationSchedulerProvider.overrideWithValue(env.scheduler),
      ],
    );
    addTearDown(container.dispose);
    final session = container.read(sessionListenerProvider);
    expect(session, isA<ReminderSessionListener>());

    await session.signedOut();

    expect(env.scheduler.pending, isEmpty);
    expect(env.scheduler.tray, isEmpty);
    final db = env.data.db;
    expect(await db.select(db.appliedNotifications).get(), isEmpty);
  });
}
