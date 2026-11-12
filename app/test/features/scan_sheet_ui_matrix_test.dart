import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/catalog/scan_flow.dart';
import 'package:pillpal/src/features/catalog/scan_sheet.dart';
import 'package:pillpal/src/features/catalog/scanner_adapter.dart';
import 'package:pillpal/src/theme/palette.dart';

import '../support/ui_matrix.dart';
import 'fake_scanner.dart';

// The scan sheet in the UI matrix (docs/redesign-plan.md, R4a; boards
// B2-ScanCamera and B2-ScanManual): the camera view and manual entry, at
// 320 px with RU text at x2.0 among the cells. Data is synthetic; the camera
// is a fake that never shows an image.

/// A valid-looking length with a wrong check digit (the board's example).
const String _wrongCheckDigit = '4600000000010';

/// The scanners the sheets made, newest last: every cell of the matrix opens
/// a sheet, and a sheet releases its scanner when it goes away.
class _Scanners {
  _Scanners({this.torch = ScannerTorch.off});

  final ScannerTorch torch;
  final List<FakeScannerAdapter> made = [];

  FakeScannerAdapter get last => made.last;

  Widget sheet() => ProviderScope(
        overrides: [
          scannerAdapterFactoryProvider.overrideWithValue(() {
            final scanner = FakeScannerAdapter()..torchState.value = torch;
            made.add(scanner);
            return scanner;
          }),
        ],
        child: const ScanSheet(),
      );
}

PillPalPalette _palette(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(ScanSheet)))
        .extension<PillPalPalette>()!;

/// Every [Icon] and [Text] of the sheet coloured as a blocking error.
Finder _dangerous(PillPalPalette palette) => find.byWidgetPredicate(
      (w) =>
          (w is Icon && w.color == palette.danger) ||
          (w is Text && w.style?.color == palette.danger),
    );

/// Scrolls [target] into view and lets the scroll activity end, so that the
/// tap lands.
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _openManual(WidgetTester tester) async {
  // The button may be below the fold of a small screen at large text.
  await _scrollTo(tester, find.byKey(const Key('scan-manual')));
  await tester.tap(find.byKey(const Key('scan-manual')));
  await tester.pump();
}

/// Types [number] and submits it with the keyboard's action: at large text
/// the scroll view of a small sheet is still animating the caret into view
/// and ignores touches, and the button itself is covered by the other tests.
Future<void> _submit(WidgetTester tester, String number) async {
  await tester.enterText(find.byKey(const Key('scan-manual-field')), number);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

void main() {
  testWidgets('camera view: viewfinder, torch, privacy text, manual entry',
      (tester) async {
    final scanners = _Scanners();
    await pumpUiMatrix(
      tester,
      (context) => scanners.sheet(),
      expectTouchTargets: true,
      expectContrast: true,
      check: (tester, cell) async {
        // A 300 viewfinder with four corner marks (B2-ScanCamera).
        final finder = find.byKey(const Key('scan-viewfinder'));
        expect(finder, findsOneWidget, reason: cell.label);
        expect(tester.getSize(finder).height, 300, reason: cell.label);
        for (final corner in ['tl', 'tr', 'bl', 'br']) {
          expect(find.byKey(Key('scan-corner-$corner')), findsOneWidget);
        }
        expect(find.byKey(const Key('scan-torch')), findsOneWidget);
        expect(find.byKey(const Key('scan-close')), findsOneWidget);
        expect(find.byKey(const Key('scan-privacy-note')), findsOneWidget);
        expect(find.byKey(const Key('scan-manual')), findsOneWidget);
        // Nothing here is a blocking error.
        expect(_dangerous(_palette(tester)), findsNothing, reason: cell.label);
      },
    );
  });

  testWidgets('a camera without a torch shows no torch button', (tester) async {
    final scanners = _Scanners(torch: ScannerTorch.unavailable);
    await pumpUiMatrix(
      tester,
      (context) => scanners.sheet(),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        expect(find.byKey(const Key('scan-torch')), findsNothing);
        expect(find.byKey(const Key('scan-viewfinder')), findsOneWidget);
      },
    );
  });

  testWidgets('the torch button switches the torch', (tester) async {
    final scanners = _Scanners();
    await pumpUiMatrix(
      tester,
      (context) => scanners.sheet(),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        final before = scanners.last.torchToggles;
        await tester.tap(find.byKey(const Key('scan-torch')));
        await tester.pump();
        expect(scanners.last.torchToggles, before + 1);
      },
    );
  });

  testWidgets('manual entry: one field, helper, camera and continue',
      (tester) async {
    final scanners = _Scanners();
    await pumpUiMatrix(
      tester,
      (context) => scanners.sheet(),
      expectTouchTargets: true,
      check: (tester, cell) async {
        await _openManual(tester);
        expect(find.byKey(const Key('scan-manual-field')), findsOneWidget);
        expect(find.byKey(const Key('scan-manual-submit')), findsOneWidget);
        expect(find.byKey(const Key('scan-use-camera')), findsOneWidget);
        // Side by side the camera button has no icon, so its one word has
        // the room (tests draw every glyph one em wide, so the real fit
        // cannot be measured here); stacked it has the icon again.
        final icon = find.descendant(
          of: find.byKey(const Key('scan-use-camera')),
          matching: find.byType(Icon),
        );
        final stacked = cell.scale * (cell.senior ? 1.3 : 1) >= 1.25;
        expect(icon, stacked ? findsOneWidget : findsNothing,
            reason: cell.label);
        expect(find.byKey(const Key('scan-viewfinder')), findsNothing);
        expect(_dangerous(_palette(tester)), findsNothing, reason: cell.label);
        expectTouchTargetsOf(tester, cell);
      },
    );
  });

  testWidgets('a wrong check digit is a danger error with an icon and text',
      (tester) async {
    final scanners = _Scanners();
    await pumpUiMatrix(
      tester,
      (context) => scanners.sheet(),
      check: (tester, cell) async {
        await _openManual(tester);
        await _submit(tester, _wrongCheckDigit);
        final error = find.byKey(const Key('scan-manual-error'));
        expect(error, findsOneWidget, reason: cell.label);
        final palette = _palette(tester);
        final icon = find.descendant(of: error, matching: find.byType(Icon));
        final text = find.descendant(of: error, matching: find.byType(Text));
        expect(tester.widget<Icon>(icon).color, palette.danger);
        expect(tester.widget<Text>(text).style?.color, palette.danger);
        if (cell.scale == uiContrastScale && cell.size == uiContrastSize) {
          await expectContrastOf(tester, cell);
        }
      },
    );
  });

  testWidgets('a wrong length is a blocking error too', (tester) async {
    final scanners = _Scanners();
    await pumpUiMatrix(
      tester,
      (context) => scanners.sheet(),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        await _openManual(tester);
        await _submit(tester, '123');
        expect(find.byKey(const Key('scan-manual-error')), findsOneWidget);
      },
    );
  });

  testWidgets('a refused camera is a calm notice, not a danger', (
    tester,
  ) async {
    final scanners = _Scanners();
    await pumpUiMatrix(
      tester,
      (context) => scanners.sheet(),
      scales: const [2.0],
      sizes: const [Size(320, 568)],
      expectTouchTargets: true,
      check: (tester, cell) async {
        scanners.last.fail(ScannerFailure.permissionDenied);
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const Key('scan-notice-permission')),
          findsOneWidget,
        );
        expect(_dangerous(_palette(tester)), findsNothing, reason: cell.label);
      },
    );
  });
}
