import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/api/auth_api.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/auth/auth_flow_state.dart';
import 'package:pillpal/src/features/settings/change_password_controller.dart';

/// Records the calls of the change; answers with a failure while one is set.
class _FakeAuthApi implements AuthApi {
  final List<String> requested = [];
  final List<(String, String)> confirmed = [];
  ApiException? requestFailure;
  ApiException? confirmFailure;

  @override
  Future<void> requestPasswordChange(String currentPassword) async {
    requested.add(currentPassword);
    if (requestFailure case final error?) {
      throw error;
    }
  }

  @override
  Future<void> confirmPasswordChange({
    required String code,
    required String newPassword,
  }) async {
    confirmed.add((code, newPassword));
    if (confirmFailure case final error?) {
      throw error;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const String _current = 'the-current-password';
const String _new = 'a-new-long-password';
const ApiException _invalidCode = ApiException('invalid_code', 400);

typedef _Setup = ({
  ProviderContainer container,
  _FakeAuthApi api,
  ChangePasswordController c,
});

_Setup _setup({bool disposeAtEnd = true}) {
  final api = _FakeAuthApi();
  final container = ProviderContainer(
    overrides: [authApiProvider.overrideWithValue(api)],
  );
  if (disposeAtEnd) {
    addTearDown(container.dispose);
  }
  // The screen keeps the autoDispose provider alive while it is open.
  container.listen(changePasswordProvider, (_, __) {});
  return (
    container: container,
    api: api,
    c: container.read(changePasswordProvider.notifier),
  );
}

ChangePasswordState _state(_Setup s) =>
    s.container.read(changePasswordProvider);

void main() {
  test('an empty password is refused before any request', () async {
    final s = _setup();

    expect(await s.c.requestCode(''), isFalse);

    expect(s.api.requested, isEmpty);
    expect(_state(s).errorCode, AuthClientErrors.passwordTooShort);
  });

  test('a right password mails a code and opens the code step', () async {
    final s = _setup();

    expect(await s.c.requestCode(_current), isTrue);

    expect(s.api.requested, [_current]);
    expect(_state(s).step, ChangePasswordStep.code);
    expect(_state(s).busy, isFalse);
    expect(s.c.holdsCurrentPassword, isTrue);
  });

  test('a wrong password stays on step 1 and is not kept', () async {
    final s = _setup();
    s.api.requestFailure = const ApiException('invalid_password', 401);

    expect(await s.c.requestCode(_current), isFalse);

    expect(_state(s).step, ChangePasswordStep.current);
    expect(_state(s).errorCode, 'invalid_password');
    expect(s.c.holdsCurrentPassword, isFalse);
  });

  test('an ended session is not reported as a restore failure', () async {
    final s = _setup();
    s.api.requestFailure = const ApiException('invalid_token', 401);

    await s.c.requestCode(_current);

    expect(_state(s).errorCode, AuthClientErrors.sessionEnded);
  });

  test('resend mails a new code with the held password', () async {
    final s = _setup();
    await s.c.requestCode(_current);

    expect(await s.c.resend(), isTrue);

    expect(s.api.requested, [_current, _current]);
    expect(_state(s).step, ChangePasswordStep.code);
  });

  test(
    'after a wipe resend asks for the password again, with a note',
    () async {
      final s = _setup();
      await s.c.requestCode(_current);

      s.c.wipe();
      expect(s.c.holdsCurrentPassword, isFalse);
      expect(await s.c.resend(), isFalse);

      expect(s.api.requested, [_current], reason: 'no request without it');
      expect(_state(s).step, ChangePasswordStep.current);
      expect(_state(s).wiped, isTrue);
      // The next code request clears the note.
      await s.c.requestCode(_current);
      expect(_state(s).wiped, isFalse);
    },
  );

  test('a wipe leaves the mailed code usable', () async {
    final s = _setup();
    await s.c.requestCode(_current);

    s.c.wipe();

    expect(await s.c.confirm(code: '123456', newPassword: _new), isTrue);
  });

  test('the password goes away with the controller', () async {
    final s = _setup(disposeAtEnd: false);
    await s.c.requestCode(_current);
    expect(s.c.holdsCurrentPassword, isTrue);

    s.container.dispose();

    expect(s.c.holdsCurrentPassword, isFalse);
  });

  test('a malformed code or short password is refused locally', () async {
    final s = _setup();
    await s.c.requestCode(_current);

    expect(await s.c.confirm(code: '12', newPassword: _new), isFalse);
    expect(_state(s).errorCode, AuthClientErrors.invalidCode);
    expect(await s.c.confirm(code: '123456', newPassword: 'short'), isFalse);
    expect(_state(s).errorCode, AuthClientErrors.passwordTooShort);
    expect(s.api.confirmed, isEmpty);
    expect(_state(s).confirmFailures, 0);
  });

  test(
    'a changed password wipes the current one and raises the notice',
    () async {
      final s = _setup();
      final notice = s.container.listen(
        passwordChangedNoticeProvider,
        (_, __) {},
      );
      await s.c.requestCode(_current);

      expect(await s.c.confirm(code: ' 123456 ', newPassword: _new), isTrue);

      expect(s.api.confirmed, [('123456', _new)]);
      expect(_state(s).step, ChangePasswordStep.done);
      expect(s.c.holdsCurrentPassword, isFalse);
      expect(notice.read(), isTrue);
    },
  );

  test('refused confirmations offer the reset after two', () async {
    final s = _setup();
    await s.c.requestCode(_current);
    s.api.confirmFailure = _invalidCode;

    await s.c.confirm(code: '123456', newPassword: _new);
    expect(_state(s).offersReset, isFalse);
    expect(_state(s).errorCode, 'invalid_code');

    await s.c.confirm(code: '123457', newPassword: _new);
    expect(_state(s).confirmFailures, AuthLimits.changeFailuresBeforeForgot);
    expect(_state(s).offersReset, isTrue);
    expect(_state(s).errorCode, 'invalid_code', reason: 'the error stays');
    expect(_state(s).step, ChangePasswordStep.code);
  });

  test('a rate limit counts as a refused confirmation', () async {
    final s = _setup();
    await s.c.requestCode(_current);
    s.api.confirmFailure = const ApiException('rate_limited', 429);

    await s.c.confirm(code: '123456', newPassword: _new);
    await s.c.confirm(code: '123456', newPassword: _new);

    expect(_state(s).offersReset, isTrue);
  });

  test('a network error is not a refused confirmation', () async {
    final s = _setup();
    await s.c.requestCode(_current);
    s.api.confirmFailure = const ApiException(ApiException.networkError, 0);

    await s.c.confirm(code: '123456', newPassword: _new);

    expect(_state(s).confirmFailures, 0);
  });
}
