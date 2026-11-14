import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pillpal/src/features/catalog/mobile_scanner_adapter.dart';
import 'package:pillpal/src/features/catalog/scanner_adapter.dart';

// The torch mapping of the real adapter, with a controller that has no
// camera: the plugin's states go in, the sheet's three states come out.

class _FakeController extends MobileScannerController {
  _FakeController({this.failToggle = false});

  final bool failToggle;
  int toggles = 0;

  void show(TorchState state) => value = value.copyWith(torchState: state);

  @override
  Future<void> toggleTorch() async {
    toggles++;
    if (failToggle) {
      throw const MobileScannerException(
        errorCode: MobileScannerErrorCode.genericError,
      );
    }
  }
}

void main() {
  test('no torch until the camera says there is one', () {
    final adapter = MobileScannerAdapter(controller: _FakeController());
    expect(adapter.torch.value, ScannerTorch.unavailable);
  });

  test('the plugin states map to unavailable, off and on (auto is off)', () {
    final controller = _FakeController();
    final adapter = MobileScannerAdapter(controller: controller);
    final expected = {
      TorchState.off: ScannerTorch.off,
      TorchState.on: ScannerTorch.on,
      TorchState.auto: ScannerTorch.off,
      TorchState.unavailable: ScannerTorch.unavailable,
    };
    for (final entry in expected.entries) {
      controller.show(entry.key);
      expect(adapter.torch.value, entry.value, reason: '${entry.key}');
    }
  });

  test('toggleTorch asks the controller', () async {
    final controller = _FakeController();
    final adapter = MobileScannerAdapter(controller: controller);
    await adapter.toggleTorch();
    expect(controller.toggles, 1);
  });

  test('a torch that cannot be switched is not an error', () async {
    final controller = _FakeController(failToggle: true);
    final adapter = MobileScannerAdapter(controller: controller);
    await adapter.toggleTorch();
    expect(controller.toggles, 1);
  });

  test('a pack scanner asks the camera for pack codes only', () {
    final adapter = MobileScannerAdapter();
    expect(adapter.controller.formats, MobileScannerAdapter.packFormats);
    expect(
      adapter.controller.formats,
      isNot(contains(BarcodeFormat.qrCode)),
    );
  });

  test('an invite scanner asks the camera for QR codes only', () {
    final adapter = MobileScannerAdapter(
      formats: MobileScannerAdapter.inviteFormats,
    );
    expect(adapter.controller.formats, [BarcodeFormat.qrCode]);
    // Frames never reach Dart, whatever the formats.
    expect(adapter.controller.returnImage, isFalse);
  });

  test('a QR code is read as a QR code, the pack codes as before', () {
    expect(MobileScannerAdapter.formatOf(BarcodeFormat.qrCode), ScanFormat.qr);
    expect(
      MobileScannerAdapter.formatOf(BarcodeFormat.ean13),
      ScanFormat.retail,
    );
    expect(
      MobileScannerAdapter.formatOf(BarcodeFormat.dataMatrix),
      ScanFormat.gs1,
    );
    expect(
      MobileScannerAdapter.formatOf(BarcodeFormat.pdf417),
      ScanFormat.unsupported,
    );
  });
}
