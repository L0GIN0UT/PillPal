import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../data/providers.dart';
import '../doses/dose_providers.dart';
import 'catalog_fill.dart';
import 'mobile_scanner_adapter.dart';
import 'scanner_adapter.dart';

// What a scan is worth and how its GTIN is resolved (ADR 0013, ADR 0015 §4,
// owner decisions D2, D3, D7). No widgets here.

/// Makes the adapter of a scan sheet; tests override it with a fake.
final scannerAdapterFactoryProvider = Provider<ScannerAdapterFactory>(
  (ref) => MobileScannerAdapter.new,
);

/// The GTIN-14 of a scanned code, or null when the code is not supported
/// (not a number the app can use, or a code of another kind).
///
/// This is the only thing taken out of a scan: the serial number and the
/// batch are dropped by the parser, and the expiry date (AI 17) is parsed
/// for validation by `parseGs1` and then not kept (D7). Never logs.
String? gtinOfScan(ScanBarcode code) {
  try {
    switch (code.format) {
      case ScanFormat.retail:
        return normalizeGtin(code.raw).gtin14;
      case ScanFormat.gs1:
        return parseGs1(code.raw).gtin.gtin14;
      case ScanFormat.unsupported:
        return null;
    }
  } on GtinException {
    return null;
  }
}

/// What the app does with a GTIN the person scanned or typed.
sealed class ScanResolution {
  const ScanResolution();
}

/// The GTIN belongs to a known product: a medication of the profile has it
/// (found on the device, works offline) or the catalog answered `found`.
final class ScanKnownProduct extends ScanResolution {
  /// Creates the resolution.
  const ScanKnownProduct(this.productId);

  /// The catalog product id.
  final String productId;
}

/// The catalog has no product for this number (`unknown`, `disputed`): the
/// person can find the product by name; the opt-in box may follow (D2) only
/// for [contributable] ones.
final class ScanUnknownGtin extends ScanResolution {
  /// Creates the resolution.
  const ScanUnknownGtin({this.contributable = true});

  /// Whether the catalog says the number is `unknown` to it: only then the
  /// opt-in box may follow (ADR 0015 section 4). A disputed number, or a
  /// `found` answer without a product, is not offered for counting.
  final bool contributable;
}

/// Why a number stays on the device.
enum ScanPrivateReason {
  /// A Restricted Circulation Number or a variable-measure item (D3):
  /// never looked up, never shared.
  restricted,

  /// The catalog could not be asked (offline, an error, no catalog).
  unreachable,
}

/// The number is kept with the medication, without a product.
final class ScanPrivateGtin extends ScanResolution {
  /// Creates the resolution.
  const ScanPrivateGtin(this.reason);

  /// Why nothing was looked up.
  final ScanPrivateReason reason;
}

/// Resolves a GTIN-14: on the device first, then one catalog lookup.
final scanFlowProvider = Provider<ScanFlow>(ScanFlow.new);

/// See [scanFlowProvider].
class ScanFlow {
  /// Creates the flow.
  ScanFlow(this._ref);

  final Ref<Object?> _ref;

  /// Resolves [gtin14] for the medication form of [profileId] (null: own).
  ///
  /// A restricted number is private without any request (D3). Otherwise a
  /// medication of the profile that has the number and a product wins
  /// without a request, so a repeat scan works offline. Only then the
  /// number is looked up (`POST /v1/gtins/lookup`, the number alone).
  Future<ScanResolution> resolve(
    String gtin14, {
    required String? profileId,
  }) async {
    if (!isShareableGtin(gtin14)) {
      return const ScanPrivateGtin(ScanPrivateReason.restricted);
    }
    final local = await _localProduct(gtin14, profileId);
    if (local != null) {
      return ScanKnownProduct(local);
    }
    final api = _ref.read(catalogApiProvider);
    if (api == null) {
      return const ScanPrivateGtin(ScanPrivateReason.unreachable);
    }
    try {
      final lookup = await api.lookupGtin(gtin14);
      return _fromLookup(lookup.status, lookup.product?.id);
    } on Exception {
      // ApiException (offline, errors) and anything the install id lookup
      // throws: the number stays on the device.
      return const ScanPrivateGtin(ScanPrivateReason.unreachable);
    }
  }

  ScanResolution _fromLookup(String status, String? productId) {
    switch (status) {
      case 'found':
        return productId == null
            ? const ScanUnknownGtin(contributable: false)
            : ScanKnownProduct(productId);
      case 'restricted':
        return const ScanPrivateGtin(ScanPrivateReason.restricted);
      case 'unknown':
        return const ScanUnknownGtin();
      default:
        return const ScanUnknownGtin(contributable: false);
    }
  }

  Future<String?> _localProduct(String gtin14, String? profileId) async {
    final id = profileId ?? (await _ref.read(selfProfileProvider.future))?.id;
    if (id == null) {
      return null;
    }
    final repository = _ref.read(medicationsRepositoryProvider);
    final rows = await repository.liveForProfile(id);
    for (final row in rows) {
      if (row.gtin == gtin14 && row.catalogProductId != null) {
        return row.catalogProductId;
      }
    }
    return null;
  }
}
