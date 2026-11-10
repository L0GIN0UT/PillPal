import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pillpal_core/pillpal_core.dart';

import '../api/api_exception.dart';
import '../api/json.dart';
import '../config.dart';
import 'catalog_dto.dart';
import 'catalog_search_dto.dart';

/// Supplies the catalog-only install id (`CatalogInstallId.current`).
typedef InstallIdSource = Future<String> Function();

/// Client of the global catalog's public API (catalog/openapi.json).
///
/// It is deliberately not built on `ApiClient` (ADR 0015 §3): there is no
/// `Authorization` header and no backend `X-Device-ID`, so a bug elsewhere
/// cannot tie a catalog request to an account; the only identity is the
/// random `X-Catalog-Install`. Lookups are `POST` with a JSON body, so what
/// a person typed or scanned never appears in a URL. Nothing here logs.
/// Calls are made on user action only; there is no background traffic.
class CatalogApi {
  /// Creates a client for the catalog at [config] (which must be enabled).
  CatalogApi({
    required http.Client httpClient,
    required CatalogConfig config,
    required InstallIdSource installId,
    Duration timeout = CatalogPolicy.requestTimeout,
  })  : _http = httpClient,
        _config = config,
        _installId = installId,
        _timeout = timeout;

  /// The header carrying the install id.
  static const String installHeader = 'X-Catalog-Install';

  /// A GTIN that is not a valid number (nothing was sent).
  static const String invalidGtin = 'invalid_gtin';

  /// A restricted GTIN: it stays on the device (nothing was sent).
  static const String gtinNotShareable = 'gtin_not_shareable';

  final http.Client _http;
  final CatalogConfig _config;
  final InstallIdSource _installId;
  final Duration _timeout;

  /// `POST /v1/search`; [q] is trimmed and must have 2..100 characters
  /// (shorter text is never sent). [lang] is `ru` or `en`; [market] puts
  /// that market first (D6). [kind] is `product`, or `substance` for the
  /// manual composition.
  Future<SearchResponse> search({
    required String q,
    required String lang,
    String? market,
    String kind = 'product',
  }) async {
    final query = q.trim();
    final length = query.runes.length;
    if (length < CatalogPolicy.searchMinLength ||
        length > CatalogPolicy.searchMaxLength) {
      throw const ApiException('validation_error', 0);
    }
    final json = await _send(
      'POST',
      '/v1/search',
      CatalogBodies.search(
        q: query,
        lang: lang,
        market: market,
        kind: kind,
      ),
    );
    return _read(json, SearchResponse.fromJson);
  }

  /// `POST /v1/gtins/lookup`. The number is normalised here and must be
  /// shareable (`docs/spec/gtin.md` §3): a malformed or restricted number
  /// stays on the device, and nothing is sent for it (`invalid_gtin`,
  /// `gtin_not_shareable`).
  Future<GtinLookup> lookupGtin(String gtin) async {
    final Gtin parsed;
    try {
      parsed = normalizeGtin(gtin);
    } on GtinException {
      throw const ApiException(invalidGtin, 0);
    }
    if (parsed.classification != GtinClassification.shareable) {
      throw const ApiException(gtinNotShareable, 0);
    }
    final json = await _send(
      'POST',
      '/v1/gtins/lookup',
      CatalogBodies.gtin(parsed.gtin14),
    );
    return _read(json, GtinLookup.fromJson);
  }

  /// `POST /v1/products/get`: one card, called when it is opened.
  Future<ProductCard> product(String id) async {
    final json = await _send(
      'POST',
      '/v1/products/get',
      CatalogBodies.product(id),
    );
    return _read(json, ProductCard.fromJson);
  }

  /// `GET /v1/sources`: attribution for Settings -> About.
  Future<List<CatalogSource>> sources() async {
    final response = await _request('GET', '/v1/sources', null);
    final Object? decoded = _decode(response);
    if (decoded is! List<Object?>) {
      throw ApiException(ApiException.invalidResponse, response.statusCode);
    }
    try {
      return [
        for (final item in decoded)
          CatalogSource.fromJson(asJsonMap(item, 'source')),
      ];
    } on FormatException {
      throw ApiException(ApiException.invalidResponse, response.statusCode);
    }
  }

  /// [parse] of [json]; a body of the wrong shape is an invalid response.
  T _read<T>(JsonMap json, T Function(JsonMap json) parse) {
    try {
      return parse(json);
    } on FormatException {
      throw const ApiException(ApiException.invalidResponse, 200);
    }
  }

  Future<JsonMap> _send(String method, String path, JsonMap body) async {
    final response = await _request(method, path, body);
    final Object? decoded = _decode(response);
    if (decoded is! Map<String, Object?>) {
      throw ApiException(ApiException.invalidResponse, response.statusCode);
    }
    return decoded;
  }

  Future<http.Response> _request(
    String method,
    String path,
    JsonMap? body,
  ) async {
    final request = http.Request(method, _config.resolve(path))
      ..headers['Accept'] = 'application/json'
      ..headers[installHeader] = await _installId();
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.bodyBytes = utf8.encode(jsonEncode(body));
    }
    final http.Response response;
    try {
      final streamed = await _http.send(request).timeout(_timeout);
      response = await http.Response.fromStream(streamed).timeout(_timeout);
    } on http.ClientException {
      throw const ApiException(ApiException.networkError, 0);
    } on TimeoutException {
      throw const ApiException(ApiException.networkError, 0);
    } on IOException {
      throw const ApiException(ApiException.networkError, 0);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _error(response);
    }
    return response;
  }

  Object? _decode(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ApiException(ApiException.invalidResponse, response.statusCode);
    }
  }

  String? _codeOf(Object? error) {
    if (error is Map<String, Object?>) {
      final value = error['code'];
      if (value is String) {
        return value;
      }
    }
    return null;
  }

  /// The catalog's `{"error": {"code"}}` envelope as an [ApiException].
  ApiException _error(http.Response response) {
    String? code;
    try {
      final Object? json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map<String, Object?>) {
        code = _codeOf(json['error']);
      }
    } on FormatException {
      code = null;
    }
    final seconds = int.tryParse(response.headers['retry-after'] ?? '');
    return ApiException(
      code ?? 'http_${response.statusCode}',
      response.statusCode,
      retryAfter: seconds == null ? null : Duration(seconds: seconds),
    );
  }
}
