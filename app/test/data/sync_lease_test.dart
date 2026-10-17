import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/clock.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/sync/sync_lease.dart';

import 'test_env.dart';

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create(signedIn: false));
  tearDown(() => env.dispose());

  /// A runner (an isolate in production): own holder ids, shared database.
  /// The delay moves the fake clock, so waiting costs no real time.
  SyncLease runner({Duration maxWait = const Duration(minutes: 5)}) =>
      SyncLease(
        db: env.db,
        clock: env.clock.call,
        newId: newUuid,
        maxWait: maxWait,
        delay: (duration) async => env.clock.advance(duration),
      );

  test('the TTL outlives a refresh request and its retry', () {
    final timeout = ApiConfig(
      baseUrl: Uri.parse('http://api.test'),
      region: 'ru',
    ).requestTimeout;
    // A request waits for the response and for its body, each up to the
    // timeout: the lease is renewed between requests, not within one.
    expect(SyncLease.defaultTtl, greaterThan(timeout * 2));
  });

  test('one holder at a time; the second runner is refused', () async {
    final first = await runner().tryAcquire();
    final second = await runner().tryAcquire();

    expect(first, isNotNull);
    expect(second, isNull);
  });

  test('an expired lease is taken over with a higher epoch', () async {
    final a = runner();
    final b = runner();
    final grantA = (await a.tryAcquire())!;

    env.clock.advance(SyncLease.defaultTtl + const Duration(seconds: 1));
    final grantB = (await b.tryAcquire())!;

    expect(grantB.epoch, grantA.epoch + 1);
    expect(grantB.holder, isNot(grantA.holder));
  });

  test('a stale holder is fenced: holds is false and ensure throws', () async {
    final a = runner();
    final b = runner();
    final stale = (await a.tryAcquire())!;
    env.clock.advance(SyncLease.defaultTtl + const Duration(seconds: 1));
    final current = (await b.tryAcquire())!;

    expect(await a.holds(stale), isFalse);
    await expectLater(a.ensure(stale), throwsA(isA<LeaseLost>()));
    expect(await b.holds(current), isTrue);
  });

  test('a stale holder cannot release or extend the new holder\'s lease',
      () async {
    final a = runner();
    final b = runner();
    final stale = (await a.tryAcquire())!;
    env.clock.advance(SyncLease.defaultTtl + const Duration(seconds: 1));
    final current = (await b.tryAcquire())!;

    await a.release(stale);
    expect(await b.holds(current), isTrue);
    expect(await runner().tryAcquire(), isNull);
  });

  test('the same holder is fenced after its own TTL even if nobody took over',
      () async {
    final a = runner();
    final grant = (await a.tryAcquire())!;

    env.clock.advance(SyncLease.defaultTtl + const Duration(seconds: 1));

    expect(await a.holds(grant), isFalse);
    await expectLater(a.ensure(grant), throwsA(isA<LeaseLost>()));
  });

  test('ensure renews the lease', () async {
    final a = runner();
    final grant = (await a.tryAcquire())!;

    for (var i = 0; i < 4; i++) {
      env.clock.advance(SyncLease.defaultTtl * 0.6);
      await a.ensure(grant);
    }

    expect(await a.holds(grant), isTrue);
    expect(await runner().tryAcquire(), isNull);
  });

  test('release frees the lease for the next runner', () async {
    final a = runner();
    final grant = (await a.tryAcquire())!;
    await a.release(grant);

    final next = await runner().tryAcquire();

    expect(next, isNotNull);
    expect(next!.epoch, grant.epoch + 1);
  });

  test('acquire waits for the holder to release', () async {
    final a = runner();
    final grant = (await a.tryAcquire())!;
    var polls = 0;
    final waiting = SyncLease(
      db: env.db,
      clock: env.clock.call,
      newId: newUuid,
      maxWait: const Duration(minutes: 5),
      delay: (duration) async {
        polls++;
        if (polls == 3) {
          await a.release(grant);
        }
        env.clock.advance(duration);
      },
    );

    final acquired = await waiting.acquire();

    expect(acquired.epoch, grant.epoch + 1);
    expect(polls, 3);
  });

  test('acquire gives up with LeaseBusy after maxWait', () async {
    await runner().tryAcquire();
    final waiting = SyncLease(
      db: env.db,
      clock: env.clock.call,
      newId: newUuid,
      maxWait: const Duration(seconds: 3),
      delay: (duration) async {
        // The holder keeps renewing in reality; here the clock stands still
        // relative to its TTL by only advancing a little.
        env.clock.advance(duration);
      },
    );

    await expectLater(waiting.acquire(), throwsA(isA<LeaseBusy>()));
  });

  group('run', () {
    test('releases the lease when the body completes or throws', () async {
      final lease = runner();
      await lease.run((grant) async => 1);
      await expectLater(
        lease.run<void>((grant) async => throw StateError('x')),
        throwsStateError,
      );

      expect(await runner().tryAcquire(), isNotNull);
    });

    test('is re-entrant: a nested run reuses the grant', () async {
      final lease = runner();
      late LeaseGrant outer;
      late LeaseGrant inner;

      await lease.run((grant) async {
        outer = grant;
        await lease.run((nested) async => inner = nested);
        // The nested run must not have released the outer lease.
        expect(await lease.holds(grant), isTrue);
      });

      expect(inner, outer);
    });

    test('another runner waits for the body', () async {
      final a = runner();
      final b = SyncLease(
        db: env.db,
        clock: env.clock.call,
        newId: newUuid,
        maxWait: const Duration(minutes: 5),
        delay: (_) => Future<void>.delayed(Duration.zero),
      );
      final gate = Completer<void>();
      final order = <String>[];

      final first = a.run((grant) async {
        order.add('a start');
        await gate.future;
        order.add('a end');
      });
      await pumpEventQueue();
      final second = b.run((grant) async => order.add('b'));
      await pumpEventQueue();
      expect(order, ['a start']);

      gate.complete();
      await Future.wait([first, second]);

      expect(order, ['a start', 'a end', 'b']);
    });

    test('does not mistake another lease object for its own run', () async {
      final a = runner(maxWait: const Duration(seconds: 1));
      final b = runner(maxWait: const Duration(seconds: 1));

      await a.run((grant) async {
        // Same zone, other runner: it is not the holder.
        await expectLater(
          b.run((nested) async {}),
          throwsA(isA<LeaseBusy>()),
        );
      });
    });
  });
}
