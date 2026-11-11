import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// What kind of code a scanner read; decides how its text is parsed.
enum ScanFormat {
  /// EAN-13, EAN-8 or UPC-A: the digits are the GTIN itself.
  retail,

  /// A GS1 element string (Data Matrix of a Russian or European pack,
  /// GS1-128): the GTIN is AI 01 (`docs/spec/gtin.md` section 5).
  gs1,

  /// Anything else (a QR code, a PDF417, ...): not read.
  unsupported,
}

/// One code the camera read. It lives only until the scan sheet has taken
/// the GTIN out of it: a marked pack's code carries a serial number that
/// identifies one pack and must never be stored, sent or logged (ADR 0013).
@immutable
class ScanBarcode {
  /// Creates a code.
  const ScanBarcode({required this.raw, required this.format});

  /// The text of the code.
  final String raw;

  /// How [raw] is to be read.
  final ScanFormat format;

  @override
  // The text is left out: it may hold a serial number.
  String toString() => 'ScanBarcode(format: ${format.name})';
}

/// The flashlight of the camera.
enum ScannerTorch {
  /// The camera has none (or it is not known yet): no button is shown.
  unavailable,

  /// Off.
  off,

  /// On.
  on,
}

/// Why the camera cannot be used; both lead to manual entry.
enum ScannerFailure {
  /// The person refused (or has turned off) the camera permission.
  permissionDenied,

  /// There is no usable camera or the scanner could not start.
  unavailable,
}

/// The camera side of scanning, behind an interface so that the sheet and
/// the whole flow are tested with a fake (the camera does not exist in
/// tests). Nothing is captured or saved: an adapter must not keep frames.
abstract interface class ScannerAdapter {
  /// The codes the camera reads, one event per code seen.
  Stream<ScanBarcode> get barcodes;

  /// Problems that make the camera unusable.
  Stream<ScannerFailure> get failures;

  /// Whether the torch exists and is on; `unavailable` hides its button.
  ValueListenable<ScannerTorch> get torch;

  /// Switches the torch on or off.
  Future<void> toggleTorch();

  /// The live preview; starting and stopping the camera follow its life.
  Widget buildPreview(BuildContext context);

  /// Stops the camera while the person types the number instead.
  Future<void> pause();

  /// Starts the camera again after [pause].
  Future<void> resume();

  /// Releases the camera.
  Future<void> dispose();
}

/// Creates the adapter of one scan sheet.
typedef ScannerAdapterFactory = ScannerAdapter Function();
