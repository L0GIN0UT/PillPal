import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:pillpal/src/features/catalog/scanner_adapter.dart';

import '../data/catalog_fixtures.dart';

// A scanner without a camera: tests push barcodes and failures into it.

/// The retail barcode (EAN-13 or UPC-A) of a GTIN-14 that starts with 0.
ScanBarcode retailCode(String gtin14) =>
    ScanBarcode(raw: gtin14.substring(1), format: ScanFormat.retail);

/// The Data Matrix of a Russian pack: GTIN, serial, expiry, key and
/// signature, with GS separators. Synthetic values only.
ScanBarcode markedPackCode({
  String gtin14 = shareableGtin,
  String serial = 'SN7Q9X2KLM4',
  String expiry = '291130',
}) {
  const gs = '\x1d';
  return ScanBarcode(
    raw: '01${gtin14}21$serial${gs}17$expiry${gs}91EE11${gs}92c2lnbmF0dXJl',
    format: ScanFormat.gs1,
  );
}

/// A QR code, which the app does not read (the camera is not asked for it;
/// the sheet still copes if an adapter hands one over).
const ScanBarcode qrCode = ScanBarcode(
  raw: 'https://example.invalid/x',
  format: ScanFormat.unsupported,
);

/// The adapter the tests drive.
class FakeScannerAdapter implements ScannerAdapter {
  final StreamController<ScanBarcode> _barcodes =
      StreamController<ScanBarcode>.broadcast();
  final StreamController<ScannerFailure> _failures =
      StreamController<ScannerFailure>.broadcast();

  /// Whether the sheet released the camera.
  bool disposed = false;

  /// Whether the camera is stopped (the person is typing).
  bool paused = false;

  /// Shows [code] to the scanner.
  void show(ScanBarcode code) => _barcodes.add(code);

  /// Makes the camera fail with [failure].
  void fail(ScannerFailure failure) => _failures.add(failure);

  @override
  Stream<ScanBarcode> get barcodes => _barcodes.stream;

  @override
  Stream<ScannerFailure> get failures => _failures.stream;

  @override
  Widget buildPreview(BuildContext context) =>
      const SizedBox(key: Key('fake-scanner-preview'), height: 120);

  @override
  Future<void> pause() async => paused = true;

  @override
  Future<void> resume() async => paused = false;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _barcodes.close();
    await _failures.close();
  }
}
