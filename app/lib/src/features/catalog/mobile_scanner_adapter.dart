import 'dart:async';

import 'package:flutter/foundation.dart';
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

  /// Retail codes, GS1 Data Matrix and GS1-128 (ADR 0013 section 5).
  static const List<BarcodeFormat> formats = [
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.upcA,
    BarcodeFormat.dataMatrix,
    BarcodeFormat.code128,
  ];

  final MobileScannerController _controller;
  final StreamController<ScannerFailure> _failures =
      StreamController<ScannerFailure>.broadcast();
  final ValueNotifier<ScannerTorch> _torch =
      ValueNotifier<ScannerTorch>(ScannerTorch.unavailable);
  bool _failed = false;

  static MobileScannerController _defaultController() {
    return MobileScannerController(
      formats: formats,
      detectionSpeed: DetectionSpeed.noDuplicates,
      // Frames are analysed in memory and never handed to Dart.
      returnImage: false,
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
  ValueListenable<ScannerTorch> get torch => _torch;

  @override
  Future<void> toggleTorch() async {
    try {
      await _controller.toggleTorch();
    } on MobileScannerException {
      // No torch after all, or the camera is not running: nothing to switch.
    }
  }

  @override
  Widget buildPreview(BuildContext context) {
    return MobileScanner(
      controller: _controller,
      // The sheet replaces the preview on a failure: no plugin text here.
      errorBuilder: (context, error) => const SizedBox.shrink(),
    );
  }

  @override
  Future<void> pause() async {
    try {
      await _controller.stop();
    } on MobileScannerException {
      // Already stopped: nothing to do.
    }
  }

  @override
  Future<void> resume() async {
    try {
      await _controller.start();
    } on MobileScannerException {
      // Already started (the preview starts it itself) or failed: the
      // failure reaches the sheet through the controller state.
    }
  }

  @override
  Future<void> dispose() async {
    _controller.removeListener(_onState);
    _torch.dispose();
    await _failures.close();
    await _controller.dispose();
  }

  void _onState() {
    _torch.value = switch (_controller.value.torchState) {
      TorchState.on => ScannerTorch.on,
      TorchState.off || TorchState.auto => ScannerTorch.off,
      TorchState.unavailable => ScannerTorch.unavailable,
    };
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
