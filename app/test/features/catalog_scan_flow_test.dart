import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/data/catalog/catalog_api.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/catalog/scan_flow.dart';
import 'package:pillpal/src/features/catalog/scanner_adapter.dart';

import '../data/catalog_fixtures.dart';
import 'catalog_ui_env.dart';
import 'fake_scanner.dart';

// What a scanned code is worth (docs/spec/gtin.md section 5, D7) and how a
// GTIN is resolved: on the device first, then one lookup, and nothing at all
// for a restricted number (D3).

void main() {
  group('the GTIN of a scan', () {
    test('a retail barcode is its own GTIN-14', () {
      expect(gtinOfScan(retailCode(shareableGtin)), shareableGtin);
    });

    test('a UPC-A is padded to a GTIN-14', () {
      const upcA = ScanBarcode(raw: '012345678905', format: ScanFormat.retail);
      expect(gtinOfScan(upcA), '00012345678905');
    });

    test('a marked pack yields the GTIN and nothing else', () {
      expect(gtinOfScan(markedPackCode()), shareableGtin);
    });

    test('a marked pack without the group separators still yields it', () {
      final code = ScanBarcode(
        raw: markedPackCode().raw.replaceAll('\x1d', ''),
        format: ScanFormat.gs1,
      );
      expect(gtinOfScan(code), shareableGtin);
    });

    test('a retail barcode with a wrong check digit is refused', () {
      const code = ScanBarcode(raw: '4607000000008', format: ScanFormat.retail);
      expect(gtinOfScan(code), isNull);
    });

    test('a QR code is not supported', () {
      expect(gtinOfScan(qrCode), isNull);
    });

    test('a Data Matrix without a GTIN is not supported', () {
      const code = ScanBarcode(raw: 'plain text', format: ScanFormat.gs1);
      expect(gtinOfScan(code), isNull);
    });

    test('a printed form of a scan never shows the code', () {
      final text = markedPackCode().toString();
      expect(text, isNot(contains('SN7Q9X2KLM4')));
      expect(text, isNot(contains(shareableGtin)));
    });
  });

  group('resolving a GTIN', () {
    testWidgets('a restricted number is private and sends nothing', (
      tester,
    ) async {
      final env = CatalogUiEnv();
      final container = await env.pump(tester);

      final resolution = await container
          .read(scanFlowProvider)
          .resolve(restrictedGtin, profileId: null);

      expect(resolution, isA<ScanPrivateGtin>());
      expect(
        (resolution as ScanPrivateGtin).reason,
        ScanPrivateReason.restricted,
      );
      expect(env.traffic.requests, isEmpty);
    });

    testWidgets('a number the catalog knows resolves to its product', (
      tester,
    ) async {
      final env = CatalogUiEnv()
        ..lookups[shareableGtin] = {
          'status': 'found',
          'product': cardJson()['product'],
          'package': null,
          'composition': null,
        };
      final container = await env.pump(tester);

      final resolution = await container
          .read(scanFlowProvider)
          .resolve(shareableGtin, profileId: null);

      expect(resolution, isA<ScanKnownProduct>());
      expect((resolution as ScanKnownProduct).productId, productA);
      expect(env.traffic.requests, hasLength(1));
      expect(env.traffic.requests.single.body, '{"gtin":"$shareableGtin"}');
    });

    for (final (status, contributable) in [
      ('unknown', true),
      ('disputed', false),
    ]) {
      testWidgets('"$status" has no product to offer', (tester) async {
        final env = CatalogUiEnv()..lookups[shareableGtin] = {'status': status};
        final container = await env.pump(tester);

        final resolution = await container
            .read(scanFlowProvider)
            .resolve(shareableGtin, profileId: null);

        expect(resolution, isA<ScanUnknownGtin>());
        expect((resolution as ScanUnknownGtin).contributable, contributable);
      });
    }

    testWidgets('"found" without a product is not offered for counting',
        (tester) async {
      final env = CatalogUiEnv()..lookups[shareableGtin] = {'status': 'found'};
      final container = await env.pump(tester);

      final resolution = await container
          .read(scanFlowProvider)
          .resolve(shareableGtin, profileId: null);

      expect((resolution as ScanUnknownGtin).contributable, isFalse);
    });

    testWidgets('a failing install id keeps the number private',
        (tester) async {
      final env = CatalogUiEnv();
      final container = await env.pump(
        tester,
        extra: [
          catalogApiProvider.overrideWithValue(
            CatalogApi(
              httpClient: MockClient((request) async => http.Response('', 500)),
              config: CatalogConfig(baseUrl: Uri.parse('https://catalog.test')),
              installId: () => throw const FormatException('no storage'),
            ),
          ),
        ],
      );

      final resolution = await container
          .read(scanFlowProvider)
          .resolve(shareableGtin, profileId: null);

      expect(
        (resolution as ScanPrivateGtin).reason,
        ScanPrivateReason.unreachable,
      );
    });

    testWidgets('an unreachable catalog keeps the number private', (
      tester,
    ) async {
      final env = CatalogUiEnv()..catalogOffline = true;
      final container = await env.pump(tester);

      final resolution = await container
          .read(scanFlowProvider)
          .resolve(shareableGtin, profileId: null);

      expect(resolution, isA<ScanPrivateGtin>());
      expect(
        (resolution as ScanPrivateGtin).reason,
        ScanPrivateReason.unreachable,
      );
    });

    testWidgets('a medication of the profile with the number wins offline', (
      tester,
    ) async {
      final env = CatalogUiEnv()..catalogOffline = true;
      final container = await env.pump(tester);
      await env.seedLinked(container);

      final resolution = await container
          .read(scanFlowProvider)
          .resolve(shareableGtin, profileId: null);

      expect((resolution as ScanKnownProduct).productId, productA);
      expect(env.traffic.requests, isEmpty, reason: 'no lookup is needed');
    });
  });
}
