import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/catalog/catalog_fill.dart';
import 'package:pillpal/src/features/catalog/scan_flow.dart';
import 'package:pillpal/src/features/catalog/scan_sheet.dart';
import 'package:pillpal/src/features/catalog/scanner_adapter.dart';
import 'package:pillpal/src/localization_delegates.dart';

import '../data/catalog_fixtures.dart';
import 'fake_scanner.dart';

// The scan sheet: the camera, its failures and the manual entry that every
// failure falls back to (4.11). The sheet hands back a GTIN-14 and where it
// came from, nothing else.

class _Opened {
  _Opened(this.scanner);

  final FakeScannerAdapter scanner;
  GtinEntered? result;
  bool closed = false;
  int pops = 0;
}

class _PopCounter extends NavigatorObserver {
  _PopCounter(this._opened);

  final _Opened _opened;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _opened.pops++;
  }
}

Future<_Opened> _open(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
}) async {
  final opened = _Opened(FakeScannerAdapter());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        scannerAdapterFactoryProvider.overrideWithValue(() => opened.scanner),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: pillPalLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        navigatorObservers: [_PopCounter(opened)],
        home: Builder(
          builder: (context) => TextButton(
            key: const Key('open'),
            onPressed: () async {
              opened.result = await showScanSheet(context);
              opened.closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
  return opened;
}

Future<void> _chooseManual(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('scan-manual')));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('scan-manual-field')), text);
  await tester.tap(find.byKey(const Key('scan-manual-submit')));
  await tester.pumpAndSettle();
}

void main() {
  group('camera', () {
    testWidgets('shows the preview and says nothing is saved', (tester) async {
      final opened = await _open(tester);

      expect(find.byKey(const Key('fake-scanner-preview')), findsOneWidget);
      expect(find.byKey(const Key('scan-privacy-note')), findsOneWidget);
      expect(find.byKey(const Key('scan-manual-field')), findsNothing);
      expect(opened.closed, isFalse);
    });

    testWidgets('a retail barcode closes the sheet with its GTIN', (
      tester,
    ) async {
      final opened = await _open(tester);

      opened.scanner.show(retailCode(shareableGtin));
      await tester.pumpAndSettle();

      expect(opened.result?.gtin14, shareableGtin);
      expect(opened.result?.source, GtinSource.scanned);
      expect(opened.scanner.disposed, isTrue, reason: 'camera is released');
    });

    testWidgets('a marked pack hands over the GTIN only', (tester) async {
      final opened = await _open(tester);

      opened.scanner.show(markedPackCode());
      await tester.pumpAndSettle();

      expect(opened.result?.gtin14, shareableGtin);
      expect(opened.result.toString(), isNot(contains('SN7Q9X2KLM4')));
    });

    testWidgets('a second code while closing changes nothing', (tester) async {
      final opened = await _open(tester);

      opened.scanner
        ..show(retailCode(shareableGtin))
        ..show(retailCode(otherShareableGtin));
      await tester.pumpAndSettle();

      expect(opened.result?.gtin14, shareableGtin);
    });

    testWidgets('an unsupported code leads to manual entry', (tester) async {
      final opened = await _open(tester);

      opened.scanner.show(qrCode);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('scan-notice-unsupported')), findsOneWidget);
      expect(find.byKey(const Key('scan-manual-field')), findsOneWidget);
      expect(opened.closed, isFalse);
    });

    testWidgets('a code that drifts into view while typing is ignored',
        (tester) async {
      final opened = await _open(tester);
      await _chooseManual(tester);
      expect(opened.scanner.paused, isTrue);

      opened.scanner.show(retailCode(shareableGtin));
      await tester.pumpAndSettle();

      expect(opened.closed, isFalse);
      expect(find.byKey(const Key('scan-manual-field')), findsOneWidget);
    });

    testWidgets('going back to the camera resumes it', (tester) async {
      final opened = await _open(tester);
      await _chooseManual(tester);

      await tester.tap(find.byKey(const Key('scan-use-camera')));
      await tester.pumpAndSettle();

      expect(opened.scanner.paused, isFalse);
    });

    testWidgets('a denied permission leads to manual entry', (tester) async {
      final opened = await _open(tester);

      opened.scanner.fail(ScannerFailure.permissionDenied);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('scan-notice-permission')), findsOneWidget);
      expect(find.byKey(const Key('scan-manual-field')), findsOneWidget);
      expect(find.byKey(const Key('scan-use-camera')), findsNothing);
    });

    testWidgets('a camera that cannot start leads to manual entry', (
      tester,
    ) async {
      final opened = await _open(tester);

      opened.scanner.fail(ScannerFailure.unavailable);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('scan-notice-unavailable')), findsOneWidget);
      expect(find.byKey(const Key('scan-manual-field')), findsOneWidget);
    });
  });

  group('manual entry', () {
    testWidgets('can be chosen and left again for the camera', (tester) async {
      await _open(tester);

      await _chooseManual(tester);
      expect(find.byKey(const Key('scan-manual-field')), findsOneWidget);

      await tester.tap(find.byKey(const Key('scan-use-camera')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fake-scanner-preview')), findsOneWidget);
    });

    testWidgets('a number with a wrong check digit is refused', (tester) async {
      final opened = await _open(tester);
      await _chooseManual(tester);

      await _type(tester, '4607000000008');

      expect(
        find.text('The check digit does not match. Check the number.'),
        findsOneWidget,
      );
      expect(opened.closed, isFalse);
    });

    testWidgets('a number of the wrong length is refused', (tester) async {
      final opened = await _open(tester);
      await _chooseManual(tester);

      await _type(tester, '46070');

      expect(
        find.text('A barcode has 8, 12, 13 or 14 digits.'),
        findsOneWidget,
      );
      expect(opened.closed, isFalse);
    });

    testWidgets('only digits, spaces and hyphens can be typed', (tester) async {
      await _open(tester);
      await _chooseManual(tester);

      await tester.enterText(
        find.byKey(const Key('scan-manual-field')),
        '46a07-000 000x0007',
      );

      final field = tester.widget<TextField>(
        find.byKey(const Key('scan-manual-field')),
      );
      expect(field.controller?.text, '4607-000 0000007');
    });

    testWidgets('a valid number with separators is accepted as typed', (
      tester,
    ) async {
      final opened = await _open(tester);
      await _chooseManual(tester);

      await _type(tester, '4607-000 000007');

      expect(opened.result?.gtin14, shareableGtin);
      expect(opened.result?.source, GtinSource.typed);
    });

    testWidgets('submitting twice closes the sheet once', (tester) async {
      final opened = await _open(tester);
      await _chooseManual(tester);
      await tester.enterText(
        find.byKey(const Key('scan-manual-field')),
        '4607000000007',
      );

      final submit = tester.widget<FilledButton>(
        find.byKey(const Key('scan-manual-submit')),
      );
      submit.onPressed!();
      submit.onPressed!();
      await tester.pumpAndSettle();

      expect(opened.pops, 1);
      expect(opened.result?.gtin14, shareableGtin);
    });

    testWidgets('a restricted number is a valid number too', (tester) async {
      final opened = await _open(tester);
      await _chooseManual(tester);

      await _type(tester, '2000000000008');

      expect(opened.result?.gtin14, restrictedGtin);
    });

    testWidgets('speaks Russian', (tester) async {
      await _open(tester, locale: const Locale('ru'));
      await _chooseManual(tester);

      await _type(tester, '4607000000008');

      expect(
        find.text('Контрольная цифра не сходится. Проверьте номер.'),
        findsOneWidget,
      );
    });
  });
}
