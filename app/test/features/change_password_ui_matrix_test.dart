import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/settings/change_password_controller.dart';
import 'package:pillpal/src/features/settings/change_password_screen.dart';

import '../support/ui_matrix.dart';

// The change-password screen (board B2-ChangePassword) in the whole UI
// matrix: light/dark, normal/senior, RU/EN, text scale 1 and 2, two sizes.

/// Controller whose state is fixed by the test.
class _FixedController extends ChangePasswordController {
  _FixedController(this.initial);

  final ChangePasswordState initial;

  @override
  ChangePasswordState build() => initial;
}

Widget _screen(ChangePasswordState state) {
  return ProviderScope(
    overrides: [
      changePasswordProvider.overrideWith(() => _FixedController(state)),
    ],
    child: const SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: ChangePasswordScreen(),
    ),
  );
}

/// Height that holds a whole screen at the largest text scale of the matrix.
const double _tallScreen = 20000;

const ChangePasswordState _step1 = ChangePasswordState();
const ChangePasswordState _step1Failed = ChangePasswordState(
  errorCode: 'invalid_password',
  wiped: true,
);
const ChangePasswordState _step2 = ChangePasswordState(
  step: ChangePasswordStep.code,
);
const ChangePasswordState _step2Refused = ChangePasswordState(
  step: ChangePasswordStep.code,
  errorCode: 'invalid_code',
  confirmFailures: 2,
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
  testWidgets('Step 1 in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(_step1Failed),
      expectTouchTargets: true,
      check: _expectKeys([
        'change-password-current',
        'change-password-next',
        'auth-error',
      ]),
    );
  });

  testWidgets('Step 2 in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(_step2Refused),
      expectTouchTargets: true,
      check: _expectKeys([
        'change-password-code',
        'change-password-new',
        'change-password-submit',
        'change-password-resend',
        'change-password-forgot',
        'auth-error',
      ]),
    );
  });

  testWidgets('both steps are readable at x2.0 on 320 px', (tester) async {
    final states = <String, ChangePasswordState>{
      'step 1': _step1,
      'step 1 error': _step1Failed,
      'step 2': _step2,
      'step 2 error': _step2Refused,
    };
    for (final entry in states.entries) {
      await pumpUiMatrix(
        tester,
        (context) => _screen(entry.value),
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

  testWidgets('the pinned action stays on screen at x2.0', (tester) async {
    final screens = <String, (ChangePasswordState, String)>{
      'step 1': (_step1, 'change-password-next'),
      'step 2': (_step2, 'change-password-submit'),
    };
    for (final entry in screens.entries) {
      final (state, key) = entry.value;
      await pumpUiMatrix(
        tester,
        (context) => _screen(state),
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
