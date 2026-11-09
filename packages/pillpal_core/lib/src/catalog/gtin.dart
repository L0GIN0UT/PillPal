/// Why a GTIN or an element string was rejected
/// (`docs/spec/gtin.md` section 1.3).
enum GtinErrorCode {
  /// The number does not have 8, 12, 13 or 14 digits (10 for an NDC).
  invalidLength('invalid_length'),

  /// The input contains something other than ASCII digits, spaces and hyphens.
  invalidCharacters('invalid_characters'),

  /// The mod-10 check digit does not match.
  invalidCheckDigit('invalid_check_digit'),

  /// An element string without a usable AI 01 (QR URL, PPN, Digital Link).
  unsupportedFormat('unsupported_format');

  const GtinErrorCode(this.wire);

  /// Stable code shared with the API and the vectors.
  final String wire;
}

/// Thrown for a rejected GTIN or element string. Never carries the input.
class GtinException implements Exception {
  /// Creates an exception with [code].
  const GtinException(this.code);

  /// What was wrong.
  final GtinErrorCode code;

  @override
  String toString() => 'GtinException(${code.wire})';
}

/// Whether a number may be shared across accounts
/// (`docs/spec/gtin.md` section 3).
enum GtinClassification {
  /// A number issued for a product; safe to share in the catalog.
  shareable('shareable'),

  /// A Restricted Circulation Number or a variable-measure item.
  restricted('restricted');

  const GtinClassification(this.wire);

  /// Stable name shared with the API and the vectors.
  final String wire;
}

/// Number of digits of the normal form.
const int gtin14Length = 14;

const Set<int> _gtinLengths = {8, 12, 13, 14};
const int _ndcLength = 10;
const String _ndcUpcPrefix = '3';
const String _variableMeasureIndicator = '9';
const int _gtin8FirstDigitIndex = 6;

// Prefixes of the GTIN-13 form: 02x, 04x, 2xx and seven leading zeros.
const List<String> _restrictedPrefixes = ['02', '04', '2', '0000000'];

/// A validated GTIN in its 14-digit form plus the length it was written with.
class Gtin {
  /// Creates a value from an already validated [gtin14].
  const Gtin({required this.gtin14, required this.sourceLength});

  /// The number left-padded with zeros to 14 digits.
  final String gtin14;

  /// 8, 12, 13 or 14: the length before padding.
  final int sourceLength;

  /// Whether the number may be shared across accounts.
  GtinClassification get classification => classifyGtin(this);

  @override
  bool operator ==(Object other) =>
      other is Gtin &&
      other.gtin14 == gtin14 &&
      other.sourceLength == sourceLength;

  @override
  int get hashCode => Object.hash(gtin14, sourceLength);

  @override
  String toString() => 'Gtin($gtin14)';
}

/// Whether [value] consists of ASCII digits only (true for the empty string).
bool isAsciiDigits(String value) {
  for (final unit in value.codeUnits) {
    if (unit < 0x30 || unit > 0x39) {
      return false;
    }
  }
  return true;
}

/// Mod-10 check digit of [body] (weights 3, 1, 3, ... from the right).
String gtinCheckDigit(String body) {
  var total = 0;
  for (var i = 0; i < body.length; i++) {
    final digit = body.codeUnitAt(body.length - 1 - i) - 0x30;
    total += digit * (i.isEven ? 3 : 1);
  }
  return ((10 - total % 10) % 10).toString();
}

String _strip(String raw) => raw.replaceAll(' ', '').replaceAll('-', '');

// Characters are checked before the length.
void _requireDigitsOfLength(String stripped, bool Function(int) lengthOk) {
  if (!isAsciiDigits(stripped)) {
    throw const GtinException(GtinErrorCode.invalidCharacters);
  }
  if (!lengthOk(stripped.length)) {
    throw const GtinException(GtinErrorCode.invalidLength);
  }
}

/// Strips spaces and hyphens, validates and left-pads to 14 digits.
///
/// Throws a [GtinException] with `invalid_characters`, `invalid_length` or
/// `invalid_check_digit`.
Gtin normalizeGtin(String raw) {
  final stripped = _strip(raw);
  _requireDigitsOfLength(stripped, _gtinLengths.contains);
  final body = stripped.substring(0, stripped.length - 1);
  if (gtinCheckDigit(body) != stripped[stripped.length - 1]) {
    throw const GtinException(GtinErrorCode.invalidCheckDigit);
  }
  return Gtin(
    gtin14: stripped.padLeft(gtin14Length, '0'),
    sourceLength: stripped.length,
  );
}

/// `restricted` for Restricted Circulation Numbers and variable-measure items.
GtinClassification classifyGtin(Gtin gtin) {
  return _isRestricted(gtin)
      ? GtinClassification.restricted
      : GtinClassification.shareable;
}

bool _isRestricted(Gtin gtin) {
  final digits = gtin.gtin14;
  if (gtin.sourceLength == 8) {
    // RCN-8: GS1-8 prefixes 000-099 and 200-299.
    final first = digits[_gtin8FirstDigitIndex];
    return first == '0' || first == '2';
  }
  if (digits[0] == _variableMeasureIndicator) {
    return true;
  }
  return _restrictedPrefixes.any(digits.substring(1).startsWith);
}

/// The GTIN-13 form of [raw], or null when its indicator digit is not 0.
String? gtin14ToGtin13(String raw) {
  final gtin14 = normalizeGtin(raw).gtin14;
  return gtin14[0] == '0' ? gtin14.substring(1) : null;
}

/// 10-digit NDC -> `3` + NDC + check digit (GTIN-12) -> padded to 14 digits.
String ndcToGtin14(String ndc) {
  final stripped = _strip(ndc);
  _requireDigitsOfLength(stripped, (length) => length == _ndcLength);
  final body = _ndcUpcPrefix + stripped;
  return (body + gtinCheckDigit(body)).padLeft(gtin14Length, '0');
}
