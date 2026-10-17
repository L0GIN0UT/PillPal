/// A decoded JSON object.
typedef JsonMap = Map<String, Object?>;

/// [value] as a JSON object, or a [FormatException] naming [what].
JsonMap asJsonMap(Object? value, String what) {
  if (value is Map<String, Object?>) {
    return value;
  }
  throw FormatException('Expected a JSON object for $what');
}

/// Typed reads of a server JSON object.
///
/// Every reader declares the keys it may read ([allowed]); reading any other
/// key is a programming error. The contract test checks each declared key set
/// against the OpenAPI snapshot, so a field the server does not send cannot be
/// read silently as `null`. Error messages name keys only, never values (the
/// values may be medical data).
class JsonReader {
  /// Wraps [json], restricted to [allowed] keys.
  JsonReader(this.json, this.allowed);

  /// The wrapped object.
  final JsonMap json;

  /// Keys this reader may read.
  final Set<String> allowed;

  Object? _value(String key) {
    if (!allowed.contains(key)) {
      throw StateError('Undeclared JSON key read: $key');
    }
    return json[key];
  }

  FormatException _invalid(String key, String expected) =>
      FormatException('Expected $expected at "$key"');

  /// A required string.
  String string(String key) {
    final value = _value(key);
    if (value is String) {
      return value;
    }
    throw _invalid(key, 'a string');
  }

  /// An optional string.
  String? stringOrNull(String key) {
    final value = _value(key);
    if (value == null || value is String) {
      return value as String?;
    }
    throw _invalid(key, 'a string or null');
  }

  /// A required integer.
  int integer(String key) {
    final value = _value(key);
    if (value is int) {
      return value;
    }
    throw _invalid(key, 'an integer');
  }

  /// An optional integer.
  int? integerOrNull(String key) {
    final value = _value(key);
    if (value == null || value is int) {
      return value as int?;
    }
    throw _invalid(key, 'an integer or null');
  }

  /// A required boolean.
  bool boolean(String key) {
    final value = _value(key);
    if (value is bool) {
      return value;
    }
    throw _invalid(key, 'a boolean');
  }

  /// An optional boolean.
  bool? booleanOrNull(String key) {
    final value = _value(key);
    if (value == null || value is bool) {
      return value as bool?;
    }
    throw _invalid(key, 'a boolean or null');
  }

  /// A required nested object.
  JsonMap object(String key) {
    final value = _value(key);
    if (value is Map<String, Object?>) {
      return value;
    }
    throw _invalid(key, 'an object');
  }

  /// An optional nested object.
  JsonMap? objectOrNull(String key) {
    final value = _value(key);
    if (value == null) {
      return null;
    }
    return object(key);
  }

  /// A required list.
  List<Object?> list(String key) {
    final value = _value(key);
    if (value is List<Object?>) {
      return value;
    }
    throw _invalid(key, 'a list');
  }

  /// A required ISO-8601 instant, in UTC.
  DateTime instant(String key) => _parseInstant(key, string(key));

  /// An optional ISO-8601 instant, in UTC.
  DateTime? instantOrNull(String key) {
    final raw = stringOrNull(key);
    return raw == null ? null : _parseInstant(key, raw);
  }

  DateTime _parseInstant(String key, String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      throw _invalid(key, 'an ISO-8601 instant');
    }
    return parsed.toUtc();
  }
}

/// Wire form of an instant: UTC ISO-8601 with microseconds when present.
String instantToJson(DateTime value) => value.toUtc().toIso8601String();
