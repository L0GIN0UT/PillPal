import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/push/alert_tap_router.dart';
import 'package:pillpal/src/push/push_payload.dart';
import 'package:pillpal/src/routing/routes.dart';

const String _profile = '22222222-2222-4222-8222-222222222222';
const String _grant = '44444444-4444-4444-8444-444444444444';

PushPayload _payload(String kind) => PushPayload.tryParse({
      'v': '1',
      't': kind,
      'p': _profile,
      if (kind.startsWith('link')) 'g': _grant else 'a': _grant,
    })!;

void main() {
  late List<String> pushed;
  late List<String> went;
  late int refreshes;
  late bool known;
  late bool signedIn;

  AlertTapRouter build() => AlertTapRouter(
        isSignedIn: () => signedIn,
        knowsProfile: (id) async => known && id == _profile,
        push: pushed.add,
        go: went.add,
        refresh: () async => refreshes++,
      );

  setUp(() {
    pushed = [];
    went = [];
    refreshes = 0;
    known = true;
    signedIn = true;
  });

  test('a missed dose of a known relative opens their day', () async {
    await build().open(_payload('missed'));
    expect(pushed, [AppRoutes.profileToday(_profile)]);
    expect(went, isEmpty);
  });

  test('a resolved alert opens the day as well', () async {
    await build().open(_payload('resolved'));
    expect(pushed, [AppRoutes.profileToday(_profile)]);
  });

  test('an unknown profile opens Family and syncs to learn about it', () async {
    known = false;
    await build().open(_payload('missed'));
    expect(pushed, isEmpty);
    expect(went, [AppRoutes.family]);
    expect(refreshes, 1);
  });

  test('link pushes open Family and refresh the links', () async {
    await build().open(_payload('link_accepted'));
    await build().open(_payload('link_restored'));
    expect(went, [AppRoutes.family, AppRoutes.family]);
    expect(refreshes, 2);
  });

  test('a failing refresh does not break the tap', () async {
    known = false;
    final router = AlertTapRouter(
      isSignedIn: () => true,
      knowsProfile: (id) async => false,
      push: pushed.add,
      go: went.add,
      refresh: () async => throw StateError('offline'),
    );
    await router.open(_payload('missed'));
    expect(went, [AppRoutes.family]);
  });

  test('a notification payload of the app opens, anything else does not',
      () async {
    final router = build();
    expect(await router.openFromPayload(_payload('missed').encode()), isTrue);
    expect(await router.openFromPayload('{"v":1}'), isFalse);
    expect(await router.openFromPayload(null), isFalse);
    expect(pushed, hasLength(1));
  });

  group('a tap before the session is known', () {
    test('waits, and routes once the user is signed in', () async {
      signedIn = false;
      final router = build();
      await router.open(_payload('missed'));
      expect(pushed, isEmpty);
      expect(went, isEmpty);
      expect(router.hasPending, isTrue);

      signedIn = true;
      await router.routePending();
      expect(pushed, [AppRoutes.profileToday(_profile)]);
      expect(router.hasPending, isFalse);
    });

    test('is routed once, not again at the next sign-in', () async {
      signedIn = false;
      final router = build();
      await router.open(_payload('missed'));
      signedIn = true;
      await router.routePending();
      await router.routePending();
      expect(pushed, hasLength(1));
    });

    test('while still signed out the payload is kept', () async {
      signedIn = false;
      final router = build();
      await router.open(_payload('missed'));
      await router.routePending();
      expect(router.hasPending, isTrue);
      expect(pushed, isEmpty);
    });

    test('only the latest tap is kept', () async {
      signedIn = false;
      final router = build();
      await router.open(_payload('link_accepted'));
      await router.open(_payload('missed'));
      signedIn = true;
      await router.routePending();
      expect(pushed, [AppRoutes.profileToday(_profile)]);
      expect(went, isEmpty);
    });
  });
}
