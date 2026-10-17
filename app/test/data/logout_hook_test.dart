import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/auth_api.dart';

import 'fake_server.dart';
import 'test_env.dart';

void main() {
  late TestEnv env;

  setUp(() async {
    env = await TestEnv.create(signedIn: false);
    await env.authApi
        .login(email: FakeServer.defaultEmail, password: 'correct-pass');
  });
  tearDown(() => env.dispose());

  test('the before-logout hook runs while the session still works', () async {
    bool? signedInDuringHook;
    final api = AuthApi(
      env.api,
      env.tokens,
      beforeLogout: () async {
        signedInDuringHook = await env.tokens.read() != null;
      },
    );
    await api.logout();
    expect(signedInDuringHook, isTrue);
    expect(await env.tokens.read(), isNull);
  });

  test('a failing hook does not stop the sign-out', () async {
    final api = AuthApi(
      env.api,
      env.tokens,
      beforeLogout: () async => throw StateError('provider gone'),
    );
    await api.logout();
    expect(await env.tokens.read(), isNull);
  });

  test('a hook that hangs is cut off', () async {
    final api = AuthApi(
      env.api,
      env.tokens,
      beforeLogout: () => Future<void>.delayed(const Duration(hours: 1)),
      beforeLogoutTimeout: const Duration(milliseconds: 10),
    );
    await api.logout();
    expect(await env.tokens.read(), isNull);
  });
}
