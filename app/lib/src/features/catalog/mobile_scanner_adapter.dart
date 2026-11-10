import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'scanner_adapter.dart';

/// The real camera: `mobile_scanner` with the **bundled** ML Kit model on
/// Android (so devices without Google Play services work; `useUnbundled`
/// must stay unset, CI checks it) and AVFoundation / Vision on iOS. Frames
/// are analysed in memory only: `returnImage` stays off.
class MobileScannerAdapter implements ScannerAdapter {
  /// Creates the adapter (one per scan sheet).
  MobileScannerAdapter({MobileScannerController? controller})
      : _controller = controller ?? _defaultController() {
    _controller.addListener(_onState);
  }

  /// Retail codes, GS1 Data Matrix and GS1-128; QR is read only to say it is
  /// not supported.
  static const List<BarcodeFormat> formats = [
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.upcA,
    BarcodeFormat.dataMatrix,
    BarcodeFormat.code128,
    BarcodeFormat.qrCode,
  ];

  final MobileScannerController _controller;
  final StreamController<ScannerFailure> _failures =
      StreamController<ScannerFailure>.broadcast();
  bool _failed = false;

  static MobileScannerController _defaultController() {
    return MobileScannerController(
      formats: formats,
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
  }

  @override
  Stream<ScanBarcode> get barcodes => _controller.barcodes.expand(
        (capture) => [
          for (final barcode in capture.barcodes)
            if (barcode.rawValue case final raw?)
              ScanBarcode(raw: raw, format: _formatOf(barcode.format)),
        ],
      );

  @override
  Stream<ScannerFailure> get failures => _failures.stream;

  @override
  Widget buildPreview(BuildContext context) {
    return MobileScanner(
      controller: _controller,
      // The sheet replaces the preview on a failure: no plugin text here.
      errorBuilder: (context, error) => const SizedBox.shrink(),
    );
  }

  @override
  Future<void> dispose() async {
    _controller.removeListener(_onState);
    await _failures.close();
    await _controller.dispose();
  }

  void _onState() {
    final error = _controller.value.error;
    if (error == null || _failed || _failures.isClosed) {
      return;
    }
    _failed = true;
    _failures.add(
      error.errorCode == MobileScannerErrorCode.permissionDenied
          ? ScannerFailure.permissionDenied
          : ScannerFailure.unavailable,
    );
  }

  static ScanFormat _formatOf(BarcodeFormat format) {
    switch (format) {
      case BarcodeFormat.ean13:
      case BarcodeFormat.ean8:
      case BarcodeFormat.upcA:
        return ScanFormat.retail;
      case BarcodeFormat.dataMatrix:
      case BarcodeFormat.code128:
        return ScanFormat.gs1;
      default:
        return ScanFormat.unsupported;
    }
  }
}
