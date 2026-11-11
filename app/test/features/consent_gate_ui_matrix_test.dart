import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/consent/consent_gate_controller.dart';
import 'package:pillpal/src/features/consent/consent_gate_screen.dart';

import '../support/ui_matrix.dart';

// The consent gate in the whole UI matrix (docs/ui-pass-plan.md, UI-4):
// light/dark, normal/senior, RU/EN, text scale 1 and 2, two screen sizes.

/// A gate whose state is fixed by the test.
class _FixedGate extends ConsentGateController {
  _FixedGate(this.initial);

  final ConsentGateState initial;

  @override
  ConsentGateState build() => initial;
}

Widget _screen(
  List<String> missing, {
  ConsentGateState state = const ConsentGateState(),
}) {
  return ProviderScope(
    overrides: [
      consentMissingProvider.overrideWith((ref) => Stream.value(missing)),
      consentGateProvider.overrideWith(() => _FixedGate(state)),
      apiConfigProvider.overrideWithValue(
        ApiConfig(baseUrl: Uri.parse('https://api.example.test'), region: 'ru'),
      ),
    ],
    // The matrix places the widget at the top start with loose constraints.
    child: const SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: ConsentGateScreen(),
    ),
  );
}

/// Height that holds a whole screen at the largest text scale of the matrix.
const double _tallScreen = 20000;

UiMatrixCheck _expectKeys(List<String> keys, {List<String> absent = const []}) {
  return (tester, cell) async {
    // The stored answer arrives after the first frame.
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
    for (final key in absent) {
      expect(
        find.byKey(Key(key)),
        findsNothing,
        reason: '"$key" is shown in "${cell.label}"',
      );
    }
    // The primary button is pinned below the list: on screen with the
    // keyboard closed however large the text (B2-README section 9.6).
    tester.view.physicalSize = cell.size;
    await tester.pump();
    final screen = Offset.zero & cell.size;
    final rect = tester.getRect(find.byKey(const Key('consent-gate-submit')));
    expect(
      screen.contains(rect.topLeft) && screen.contains(rect.bottomRight),
      isTrue,
      reason: '"consent-gate-submit" is off screen in "${cell.label}": $rect',
    );
  };
}

void main() {
  testWidgets('Gate in the matrix: everything missing, paused, with an error',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        const ['health_data', 'terms', 'privacy'],
        state: const ConsentGateState(errorCode: 'rate_limited'),
      ),
      expectTouchTargets: true,
      check: _expectKeys([
        'consent-terms',
        'consent-privacy',
        'consent-health',
        'consent-health-card',
        'consent-health-version',
        'consent-gate-paused',
        'auth-error',
        'consent-gate-submit',
        'consent-gate-sign-out',
        'consent-gate-delete',
      ]),
    );
  });

  testWidgets('Gate in the matrix: one text missing, the app is out of date',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        const ['terms'],
        state: const ConsentGateState(outdated: true),
      ),
      expectTouchTargets: true,
      check: _expectKeys(
        [
          'consent-terms',
          'auth-error',
          'consent-gate-submit',
          'consent-gate-sign-out',
          'consent-gate-delete',
        ],
        absent: ['consent-health-card', 'consent-gate-paused'],
      ),
    );
  });
}
