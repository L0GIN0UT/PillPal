import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'json.dart';

/// Runs [call], reporting every transport failure as a network error.
Future<T> guardTransport<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on http.ClientException {
    throw const ApiException(ApiException.networkError, 0);
  } on TimeoutException {
    throw const ApiException(ApiException.networkError, 0);
  } on IOException {
    // Sockets, TLS handshakes (HandshakeException), HTTP framing.
    throw const ApiException(ApiException.networkError, 0);
  }
}

/// What is read of the body of a refused download (an error envelope).
const int errorBodyCap = 64 * 1024;

/// A small response (an error envelope, a JSON answer) read whole.
Future<http.Response> readWhole(
  http.StreamedResponse streamed,
  Duration timeout,
) {
  return guardTransport(
    () => http.Response.fromStream(streamed).timeout(timeout),
  );
}

/// Reads at most [maxBytes] of [streamed] (the rest is dropped and the stream
/// cancelled), each chunk within [timeout]: the error envelope of a refused
/// download, which must never be able to fill the memory.
Future<http.Response> readCapped(
  http.StreamedResponse streamed, {
  required int maxBytes,
  required Duration timeout,
}) {
  return guardTransport(() async {
    final body = <int>[];
    await for (final chunk in streamed.stream.timeout(timeout)) {
      body.addAll(chunk);
      if (body.length >= maxBytes) {
        break;
      }
    }
    return http.Response.bytes(
      body.length > maxBytes ? body.sublist(0, maxBytes) : body,
      streamed.statusCode,
      headers: streamed.headers,
    );
  });
}

/// The decoded JSON object of a 2xx [response] (null for an empty body); any
/// other status throws the [ApiException] of the error envelope.
JsonMap? decodeResponse(http.Response response) {
  final status = response.statusCode;
  if (status >= 200 && status < 300) {
    if (response.bodyBytes.isEmpty) {
      return null;
    }
    return asJsonMap(_parse(response), 'response');
  }
  final error = errorEnvelopeOf(response);
  final details = error?['details'];
  final code = error?['code'];
  throw ApiException(
    code is String ? code : 'http_$status',
    status,
    retryAfter: _retryAfter(response),
    details: details is Map<String, Object?> ? details : null,
  );
}

Object? _parse(http.Response response) {
  try {
    // FastAPI sends application/json without a charset; JSON is UTF-8.
    return jsonDecode(utf8.decode(response.bodyBytes));
  } on FormatException {
    throw ApiException(ApiException.invalidResponse, response.statusCode);
  }
}

/// The `error` object of the envelope `{"error": {"code", ...}}`.
Map<String, Object?>? errorEnvelopeOf(http.Response response) {
  try {
    final Object? json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is Map<String, Object?>) {
      final error = json['error'];
      if (error is Map<String, Object?>) {
        return error;
      }
    }
  } on FormatException {
    return null;
  }
  return null;
}

Duration? _retryAfter(http.Response response) {
  final seconds = int.tryParse(response.headers['retry-after'] ?? '');
  return seconds == null ? null : Duration(seconds: seconds);
}
