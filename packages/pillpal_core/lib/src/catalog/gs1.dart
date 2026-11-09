import 'gtin.dart';

/// What is kept of a scanned GS1 element string
/// (`docs/spec/gtin.md` section 5).
///
/// Deliberately has no lot or serial number field: AI 10 and AI 21 are
/// consumed and discarded by [parseGs1].
class Gs1Result {
  /// Creates a result.
  const Gs1Result({required this.gtin, this.expiry, this.partial = false});

  /// The number of AI 01.
  final Gtin gtin;

  /// AI 17 as a calendar date (UTC midnight), or null.
  final DateTime? expiry;

  /// Whether an unknown or malformed element ended the parse.
  final bool partial;

  @override
  bool operator ==(Object other) =>
      other is Gs1Result &&
      other.gtin == gtin &&
      other.partial == partial &&
      _sameDate(other.expiry, expiry);

  @override
  int get hashCode =>
      Object.hash(gtin, partial, expiry?.microsecondsSinceEpoch);

  @override
  String toString() => 'Gs1Result($gtin)';
}

bool _sameDate(DateTime? a, DateTime? b) {
  if (a == null || b == null) {
    return a == b;
  }
  return a.isAtSameMomentAs(b);
}

/// The group separator that ends a variable-length element.
const String groupSeparator = '\x1d';

const List<String> _symbologyIdentifiers = ['d2', 'C1', 'Q3', 'e0'];
const String _aiGtin = '01';
const String _aiExpiry = '17';
const int _aiLength = 2;
const int _gtinElementLength = _aiLength + gtin14Length;
const int _expiryBaseYear = 2000;

// First two digits of a predefined-length AI -> characters of AI and data.
const Map<String, int> _predefinedLengths = {
  '00': 20,
  '01': 16,
  '02': 16,
  '03': 16,
  '04': 18,
  '11': 8,
  '12': 8,
  '13': 8,
  '14': 8,
  '15': 8,
  '16': 8,
  '17': 8,
  '18': 8,
  '19': 8,
  '20': 4,
  '31': 10,
  '32': 10,
  '33': 10,
  '34': 10,
  '35': 10,
  '36': 10,
  '41': 16,
};

// AIs ended by a group separator (or the end of the data).
const Set<String> _variableAis = {
  '10',
  '21',
  '22',
  '240',
  '241',
  '30',
  '37',
  '710',
  '711',
  '712',
  '713',
  '714',
  '715',
  '90',
  '91',
  '92',
  '93',
  '94',
  '95',
  '96',
  '97',
  '98',
  '99',
};

String _slice(String data, int start, int end) {
  final stop = end < data.length ? end : data.length;
  return start >= stop ? '' : data.substring(start, stop);
}

String _stripSymbologyIdentifier(String data) {
  for (final identifier in _symbologyIdentifiers) {
    if (data.startsWith(']$identifier')) {
      return data.substring(identifier.length + 1);
    }
  }
  return data;
}

bool _isVariableAi(String data, int pos) {
  return _variableAis.contains(_slice(data, pos, pos + 3)) ||
      _variableAis.contains(_slice(data, pos, pos + 2));
}

DateTime? _parseExpiry(String value) {
  final year = _expiryBaseYear + int.parse(value.substring(0, 2));
  final month = int.parse(value.substring(2, 4));
  var day = int.parse(value.substring(4, 6));
  if (month < 1 || month > 12) {
    return null;
  }
  // Day 0 of the next month is the last day of this one.
  final lastDay = DateTime.utc(year, month + 1, 0).day;
  if (day == 0) {
    day = lastDay;
  }
  return day <= lastDay ? DateTime.utc(year, month, day) : null;
}

Gtin _readGtin(String data, int pos) {
  final start = pos + _aiLength;
  final value = _slice(data, start, start + gtin14Length);
  if (value.contains(groupSeparator) || value.length < gtin14Length) {
    throw const GtinException(GtinErrorCode.invalidLength);
  }
  if (!isAsciiDigits(value)) {
    throw const GtinException(GtinErrorCode.invalidCharacters);
  }
  final body = value.substring(0, gtin14Length - 1);
  if (gtinCheckDigit(body) != value[gtin14Length - 1]) {
    throw const GtinException(GtinErrorCode.invalidCheckDigit);
  }
  return Gtin(gtin14: value, sourceLength: gtin14Length);
}

// The whole numeric predefined-length element at [pos], or null if malformed.
String? _predefinedElement(String data, int pos) {
  final length = _predefinedLengths[_slice(data, pos, pos + _aiLength)];
  if (length == null) {
    return null;
  }
  final element = _slice(data, pos, pos + length);
  return element.length == length && isAsciiDigits(element) ? element : null;
}

Gs1Result _result(Gtin? gtin, DateTime? expiry, {required bool partial}) {
  if (gtin == null) {
    throw const GtinException(GtinErrorCode.unsupportedFormat);
  }
  return Gs1Result(gtin: gtin, expiry: expiry, partial: partial);
}

/// Extracts GTIN and expiry from a scanned GS1 element string.
///
/// Strips a symbology identifier (`]d2`, `]C1`, `]Q3`, `]e0`) and group
/// separators between elements. Lot (AI 10) and serial number (AI 21) are
/// consumed and discarded. After a valid AI 01 the first unknown or malformed
/// element ends the parse and sets [Gs1Result.partial].
///
/// Throws a [GtinException] with `unsupported_format` when there is no usable
/// AI 01, or with a GTIN error code when AI 01 is malformed.
Gs1Result parseGs1(String data) {
  final text = data.startsWith(']') ? _stripSymbologyIdentifier(data) : data;
  Gtin? gtin;
  DateTime? expiry;
  var pos = 0;
  while (true) {
    while (pos < text.length && text[pos] == groupSeparator) {
      pos++;
    }
    if (pos >= text.length) {
      return _result(gtin, expiry, partial: false);
    }
    final prefix = _slice(text, pos, pos + _aiLength);
    final element = _predefinedElement(text, pos);
    if (prefix == _aiGtin && gtin == null) {
      gtin = _readGtin(text, pos);
      pos += _gtinElementLength;
    } else if (element != null) {
      if (prefix == _aiExpiry && gtin != null) {
        expiry = _parseExpiry(element.substring(_aiLength));
      }
      pos += element.length;
    } else if (_predefinedLengths.containsKey(prefix)) {
      return _result(gtin, expiry, partial: true);
    } else if (_isVariableAi(text, pos)) {
      final end = text.indexOf(groupSeparator, pos);
      pos = end < 0 ? text.length : end;
    } else {
      return _result(gtin, expiry, partial: true);
    }
  }
}
