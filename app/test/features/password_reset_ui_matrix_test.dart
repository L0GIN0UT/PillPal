import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/auth/auth_flow.dart';
import 'package:pillpal/src/features/auth/auth_session.dart';
import 'package:pillpal/src/features/auth/credentials_screens.dart';
import 'package:pillpal/src/features/auth/password_reset_screens.dart';
import 'package:pillpal/src/features/common/local_time.dart';

import '../support/ui_matrix.dart';

// The password-reset screens (R7b) and the sign-in link in the whole UI
// matrix: light/dark, normal/senior, RU/EN, text scale 1 and 2, two sizes.

/// Auth flow whose state is fixed by the test.
class _FixedFlow extends AuthFlowController {
  _FixedFlow(this.initial);

  final AuthFlowState initial;

  @override
  AuthFlowState build() => initial;
}

Widget _screen(Widget screen, {AuthFlowState flow = const AuthFlowState()}) {
  return ProviderScope(
    overrides: [
      authFlowProvider.overrideWith(() => _FixedFlow(flow)),
      hasBoundLocalDataProvider.overrideWith((ref) async => false),
      deviceTimeZoneProvider.overrideWithValue('Europe/Moscow'),
      apiConfigProvider.overrideWithValue(
        ApiConfig(baseUrl: Uri.parse('https://api.example.test'), region: 'ru'),
      ),
    ],
    child: SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: screen,
    ),
  );
}

/// Height that holds a whole screen at the largest text scale of the matrix.
const double _tallScreen = 20000;

const AuthFlowState _sent = AuthFlowState(email: 'user@example.test');
const AuthFlowState _failed = AuthFlowState(
  email: 'user@example.test',
  errorCode: 'invalid_code',
);

UiMatrixCheck _expectKeys(List<String> keys) {
  return (tester, cell) async {
    await tester.pump();
    tester.view.physicalSize = Size(cell.size.width, _tallScreen);
    await tester.pump();
    expectTouchTargetsOf(tester, cell);
    for (final key in keys) {
      expect(
        find.byKey(Key(key)),
        findsOneWidget,
        reason: '"$key" is missing in "${cell.label}"',
      );
    }
  };
}

void main() {
  testWidgets('Forgot in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        const ForgotPasswordScreen(email: 'user@example.test'),
        flow: const AuthFlowState(errorCode: 'rate_limited'),
      ),
      expectTouchTargets: true,
      check: _expectKeys(['auth-email', 'forgot-submit', 'auth-error']),
    );
  });

  testWidgets('Reset in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(const ResetPasswordScreen(), flow: _failed),
      expectTouchTargets: true,
      check: _expectKeys([
        'reset-email',
        'reset-code',
        'auth-password',
        'reset-submit',
        'reset-resend',
        'auth-error',
      ]),
    );
  });

  testWidgets('Login shows the forgot link as a tap target', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(const LoginScreen()),
      expectTouchTargets: true,
      check: _expectKeys(['auth-forgot']),
    );
  });

  testWidgets('Register has no forgot link', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(const RegisterScreen()),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        await tester.pump();
        expect(find.byKey(const Key('auth-forgot')), findsNothing);
      },
    );
  });

  testWidgets('the reset screens are readable at x2.0 on 320 px',
      (tester) async {
    final states = <String, (Widget, AuthFlowState)>{
      'forgot': (const ForgotPasswordScreen(), const AuthFlowState()),
      'forgot error': (
        const ForgotPasswordScreen(),
        const AuthFlowState(errorCode: 'rate_limited'),
      ),
      'reset': (const ResetPasswordScreen(), _sent),
      'reset error': (const ResetPasswordScreen(), _failed),
      'login link': (const LoginScreen(), const AuthFlowState()),
    };
    for (final entry in states.entries) {
      final (screen, flow) = entry.value;
      await pumpUiMatrix(
        tester,
        (context) => _screen(screen, flow: flow),
        scales: const [2.0],
        sizes: const [Size(320, 568)],
        check: (tester, cell) async {
          // Tall, so nothing is scrolled under the pinned button (the pixel
          // guideline would measure it against that button).
          tester.view.physicalSize = Size(cell.size.width, _tallScreen / 5);
          await tester.pump();
          try {
            await expectContrastOf(tester, cell);
          } on TestFailure catch (e) {
            fail('contrast of the ${entry.key} screen: ${e.message}');
          }
        },
      );
    }
  });

  testWidgets('the reset screens meet the contrast of the mode',
      (tester) async {
    for (final screen in [
      const ForgotPasswordScreen(),
      const ResetPasswordScreen(),
    ]) {
      await pumpUiMatrix(
        tester,
        (context) => _screen(screen, flow: _sent),
        expectContrast: true,
        scales: const [1.0],
        sizes: const [Size(360, 800)],
      );
    }
  });

  testWidgets('the pinned action stays on screen at x2.0', (tester) async {
    final screens = <String, (Widget, String)>{
      'forgot': (const ForgotPasswordScreen(), 'forgot-submit'),
      'reset': (const ResetPasswordScreen(), 'reset-submit'),
    };
    for (final entry in screens.entries) {
      final (screen, key) = entry.value;
      await pumpUiMatrix(
        tester,
        (context) => _screen(screen, flow: _sent),
        scales: const [2.0],
        sizes: const [Size(320, 568)],
        check: (tester, cell) async {
          final rect = tester.getRect(find.byKey(Key(key)));
          expect(
            (Offset.zero & cell.size).contains(rect.bottomRight),
            isTrue,
            reason: '"$key" is off screen in "${cell.label}": $rect',
          );
        },
      );
    }
  });
}
