import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/push/push_provider_client.dart';
import 'package:pillpal/src/push/push_service.dart';
import 'package:pillpal/src/push/push_state_store.dart';

import '../data/test_env.dart' show FakeClock;
import 'fake_push.dart';

const ApiException _offline = ApiException(ApiException.networkError, 0);

void main() {
  late AppDatabase db;
  late PushStateStore state;
  late FakePushNeed need;
  late FakeTokenGateway gateway;
  late FakePushClient fcm;
  late FakePushClient rustore;
  late FakeClock clock;
  late String? user;
  late List<Map<String, String>> delivered;
  late PushService service;

  PushService build({FakePushClient? first, FakePushClient? second}) {
    return PushService(
      need: need,
      gateway: gateway,
      state: state,
      selector: PushProviderSelector(
        platform: TargetPlatform.android,
        fcm: first ?? fcm,
        rustore: second ?? rustore,
      ),
      clock: clock.call,
      boundUserId: () async => user,
      onMessage: (client, data) async {
        delivered.add(data);
      },
    );
  }

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = AppDatabase(NativeDatabase.memory());
    state = PushStateStore(db);
    need = FakePushNeed();
    gateway = FakeTokenGateway();
    fcm = FakePushClient(PushProviderKind.fcm);
    rustore = FakePushClient(PushProviderKind.rustore, token: 'rustore-token');
    clock = FakeClock(DateTime.utc(2026, 10, 16, 9));
    user = 'user-1';
    delivered = [];
    service = build();
  });

  tearDown(() async {
    await service.dispose();
    await fcm.dispose();
    await rustore.dispose();
    await db.close();
  });

  group('registration only under the need rule', () {
    test('no need: nothing is started and nothing is registered', () async {
      final status = await service.reconcile();
      expect(status, PushStatus.idle);
      expect(fcm.starts, 0);
      expect(gateway.registered, isEmpty);
      expect(gateway.unregistered, 0);
      expect(await state.provider(), isNull);
    });

    test('the need appears: the token is registered and remembered', () async {
      need.needed = true;
      final status = await service.reconcile();
      expect(
        status,
        const PushStatus(
          PushAvailability.registered,
          provider: PushProviderKind.fcm,
        ),
      );
      expect(gateway.registered, hasLength(1));
      expect(gateway.registered.single.provider, PushProviderKind.fcm);
      expect(gateway.registered.single.registration.token, 'synthetic-token-1');
      expect(gateway.registeredFor.single, 'user-1');
      expect(await state.provider(), PushProviderKind.fcm);
    });

    test('an APNs registration carries the environment of the build', () async {
      final apns = FakePushClient(
        PushProviderKind.apns,
        environment: 'sandbox',
        rendersLocally: false,
      );
      final ios = PushService(
        need: need,
        gateway: gateway,
        state: state,
        selector: PushProviderSelector(
          platform: TargetPlatform.iOS,
          apns: apns,
        ),
        clock: clock.call,
        boundUserId: () async => user,
        onMessage: (client, data) async {},
      );
      addTearDown(() async {
        await ios.dispose();
        await apns.dispose();
      });
      need.needed = true;
      await ios.reconcile();
      expect(gateway.registered.single.provider, PushProviderKind.apns);
      expect(gateway.registered.single.registration.apnsEnvironment, 'sandbox');
    });

    test('while the need lasts the same token is not registered again',
        () async {
      need.needed = true;
      await service.reconcile();
      await service.reconcile();
      await service.reconcile();
      expect(gateway.registered, hasLength(1));
    });

    test('concurrent triggers share one run', () async {
      need.needed = true;
      await Future.wait([service.reconcile(), service.reconcile()]);
      expect(gateway.registered, hasLength(1));
    });

    test('a refreshed token is registered again', () async {
      need.needed = true;
      await service.reconcile();
      fcm.token = 'synthetic-token-2';
      fcm.refreshController.add(
        const PushRegistration(token: 'synthetic-token-2'),
      );
      await pumpEventQueue();
      // Joins the run the refresh started (or is a no-op once it is over).
      await service.reconcile();
      expect(gateway.registered, hasLength(2));
      expect(
        gateway.registered.last.registration.token,
        'synthetic-token-2',
      );
    });

    test('the same token for another account is registered for it', () async {
      need.needed = true;
      await service.reconcile();
      user = 'user-2';
      await service.reconcile();
      expect(gateway.registeredFor, ['user-1', 'user-2']);
    });

    test('the need ends: the token is deleted and given back', () async {
      need.needed = true;
      await service.reconcile();
      need.needed = false;
      final status = await service.reconcile();
      expect(status, PushStatus.idle);
      expect(gateway.unregistered, 1);
      expect(fcm.stops, 1);
      expect(await state.provider(), isNull);
    });

    test('a need that ends and returns registers once more', () async {
      need.needed = true;
      await service.reconcile();
      need.needed = false;
      await service.reconcile();
      need.needed = true;
      await service.reconcile();
      expect(gateway.registered, hasLength(2));
    });

    test('a need that cannot be told changes nothing', () async {
      need.needed = true;
      await service.reconcile();
      need.needed = null;
      final status = await service.reconcile();
      expect(status.availability, PushAvailability.registered);
      expect(gateway.unregistered, 0);
      expect(await state.provider(), PushProviderKind.fcm);
    });

    test('nobody signed in: nothing happens', () async {
      need.needed = true;
      user = null;
      final status = await service.reconcile();
      expect(status, PushStatus.idle);
      expect(fcm.starts, 0);
      expect(gateway.registered, isEmpty);
    });
  });

  group('failures are retried by the next trigger', () {
    test('a failed registration is not remembered', () async {
      need.needed = true;
      gateway.error = _offline;
      expect((await service.reconcile()).availability, PushAvailability.failed);
      expect(await state.provider(), isNull);
      gateway.error = null;
      expect(
        (await service.reconcile()).availability,
        PushAvailability.registered,
      );
      expect(gateway.registered, hasLength(1));
    });

    test('a failed deletion keeps the registration for a retry', () async {
      need.needed = true;
      await service.reconcile();
      need.needed = false;
      gateway.error = _offline;
      expect((await service.reconcile()).availability, PushAvailability.failed);
      expect(await state.provider(), PushProviderKind.fcm);
      expect(fcm.stops, 0);
      gateway.error = null;
      expect(await service.reconcile(), PushStatus.idle);
      expect(gateway.unregistered, 1);
      expect(await state.provider(), isNull);
    });

    test('a provider that has no token is a failure, not a registration',
        () async {
      need.needed = true;
      fcm.token = null;
      expect((await service.reconcile()).availability, PushAvailability.failed);
      expect(gateway.registered, isEmpty);
    });

    test('a provider that throws is a failure and nothing escapes', () async {
      need.needed = true;
      fcm.startError = StateError('platform failure');
      expect((await service.reconcile()).availability, PushAvailability.failed);
    });
  });

  group('providers', () {
    test('no provider on the device: unavailable, nothing registered',
        () async {
      need.needed = true;
      fcm.available = false;
      rustore.available = false;
      final status = await service.reconcile();
      expect(status.availability, PushAvailability.unavailable);
      expect(gateway.registered, isEmpty);
      expect(fcm.starts + rustore.starts, 0);
    });

    test('without Google services the RuStore token is used', () async {
      need.needed = true;
      fcm.available = false;
      await service.reconcile();
      expect(gateway.registered.single.provider, PushProviderKind.rustore);
      expect(gateway.registered.single.registration.token, 'rustore-token');
    });

    test('a changed provider gives the old token back and registers anew',
        () async {
      need.needed = true;
      await service.reconcile();
      fcm.available = false;
      await service.reconcile();
      expect(fcm.stops, 1);
      expect(gateway.registered.last.provider, PushProviderKind.rustore);
      expect(await state.provider(), PushProviderKind.rustore);
      expect(gateway.unregistered, 0, reason: 'the new registration replaces');
    });

    test('a device that lost its provider drops the old registration',
        () async {
      need.needed = true;
      await service.reconcile();
      fcm.available = false;
      rustore.available = false;
      final status = await service.reconcile();
      expect(status.availability, PushAvailability.unavailable);
      expect(gateway.unregistered, 1);
      expect(await state.provider(), isNull);
    });
  });

  group('pushes while the app runs', () {
    test('data of the registered provider reaches the handler', () async {
      need.needed = true;
      await service.reconcile();
      fcm.messageController.add({'t': 'missed'});
      await pumpEventQueue();
      expect(delivered, [
        {'t': 'missed'},
      ]);
    });

    test('nothing is delivered once the need has ended', () async {
      need.needed = true;
      await service.reconcile();
      need.needed = false;
      await service.reconcile();
      fcm.messageController.add({'t': 'missed'});
      await pumpEventQueue();
      expect(delivered, isEmpty);
    });
  });

  group('sign-out', () {
    test('deletes the token while the session works', () async {
      need.needed = true;
      await service.reconcile();
      await service.unregister();
      expect(gateway.unregistered, 1);
      expect(fcm.stops, 1);
      expect(await state.provider(), isNull);
      expect(service.status, PushStatus.idle);
    });

    test('offline it still cleans up this side and never throws', () async {
      need.needed = true;
      await service.reconcile();
      gateway.error = _offline;
      await service.unregister();
      expect(fcm.stops, 1);
      expect(await state.provider(), isNull);
    });

    test('without a registration it does nothing', () async {
      await service.unregister();
      expect(gateway.unregistered, 0);
      expect(fcm.stops, 0);
    });

    test('registers again after the next sign-in', () async {
      need.needed = true;
      await service.reconcile();
      await service.unregister();
      await service.reconcile();
      expect(gateway.registered, hasLength(2));
    });
  });
}
