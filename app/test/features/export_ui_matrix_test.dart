import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/privacy/export_controller.dart';
import 'package:pillpal/src/features/privacy/export_screen.dart';

import '../support/ui_matrix.dart';

// The export screen (ADR 0016 §8) in the whole UI matrix: light/dark,
// normal/senior, RU/EN, text scale 1 and 2, two sizes, for every phase.

/// Controller whose state is fixed by the test.
class _FixedController extends ExportController {
  _FixedController(this.initial);

  final ExportState initial;

  @override
  ExportState build() => initial;
}

Widget _screen(ExportState state) {
  return ProviderScope(
    overrides: [
      exportControllerProvider.overrideWith(() => _FixedController(state)),
    ],
    child: const SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: ExportScreen(),
    ),
  );
}

/// Height that holds a whole screen at the largest text scale of the matrix.
const double _tallScreen = 20000;

/// A phase and what must be on screen in it.
class _Phase {
  const _Phase(this.state, this.present, [this.absent = const []]);

  final ExportState state;
  final List<String> present;
  final List<String> absent;
}

const Map<String, _Phase> _phases = {
  'form': _Phase(ExportState(), ['export-password', 'export-submit']),
  'form with the cooldown': _Phase(
    ExportState(
      errorCode: 'export_rate_limited',
      retryAfter: Duration(hours: 1),
    ),
    ['export-password', 'export-submit', 'export-error'],
  ),
  'form with a wrong password': _Phase(
    ExportState(errorCode: 'invalid_password'),
    ['export-password', 'export-submit', 'export-error'],
  ),
  'building': _Phase(
    ExportState(phase: ExportPhase.building),
    ['export-building'],
    ['export-submit', 'export-password'],
  ),
  'downloading': _Phase(
    ExportState(phase: ExportPhase.downloading),
    ['export-downloading'],
    ['export-submit'],
  ),
  'ready': _Phase(
    ExportState(phase: ExportPhase.ready),
    ['export-share'],
    ['export-error'],
  ),
  'ready after a share sheet that failed': _Phase(
    ExportState(phase: ExportPhase.ready, errorCode: 'generic'),
    ['export-share', 'export-error'],
  ),
  'done': _Phase(ExportState(phase: ExportPhase.done), ['export-close']),
  'failed, can check again': _Phase(
    ExportState(
      phase: ExportPhase.failed,
      errorCode: 'network_error',
      resumable: true,
    ),
    ['export-resume', 'export-error'],
    ['export-restart'],
  ),
  'failed, lost': _Phase(
    ExportState(phase: ExportPhase.failed, errorCode: 'export_transfer_lost'),
    ['export-restart', 'export-error'],
    ['export-resume'],
  ),
  'failed, too large': _Phase(
    ExportState(phase: ExportPhase.failed, errorCode: 'export_too_large'),
    ['export-error'],
    ['export-restart', 'export-resume'],
  ),
};

UiMatrixCheck _expect(_Phase phase) {
  return (tester, cell) async {
    await tester.pump();
    tester.view.physicalSize = Size(cell.size.width, _tallScreen);
    await tester.pump();
    expectTouchTargetsOf(tester, cell);
    for (final key in phase.present) {
      expect(
        find.byKey(Key(key)),
        findsOneWidget,
        reason: '"$key" is missing in "${cell.label}"',
      );
    }
    for (final key in phase.absent) {
      expect(
        find.byKey(Key(key)),
        findsNothing,
        reason: '"$key" is shown in "${cell.label}"',
      );
    }
  };
}

void main() {
  for (final entry in _phases.entries) {
    testWidgets('Export, ${entry.key}, in the matrix', (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => _screen(entry.value.state),
        expectTouchTargets: true,
        check: _expect(entry.value),
      );
    });
  }

  testWidgets('the phases are readable at x2.0 on 320 px', (tester) async {
    for (final entry in _phases.entries) {
      await pumpUiMatrix(
        tester,
        (context) => _screen(entry.value.state),
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
            fail('contrast of the "${entry.key}" phase: ${e.message}');
          }
        },
      );
    }
  });
}
