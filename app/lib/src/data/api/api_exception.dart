/// A failed API call: the server's stable error `code` and HTTP [status].
///
/// [status] is 0 when no HTTP response was received. The server's message is
/// not kept: the app localizes [code] (see `backend/app/errors.py`).
class ApiException implements Exception {
  /// Creates an exception.
  const ApiException(this.code, this.status, {this.retryAfter});

  /// No response: offline, DNS, TLS or timeout.
  static const String networkError = 'network_error';

  /// A response the client cannot interpret.
  static const String invalidResponse = 'invalid_response';

  /// No stored session (signed out).
  static const String unauthorized = 'unauthorized';

  /// Stable error code, e.g. `email_not_verified`, `rate_limited`.
  final String code;

  /// HTTP status, or 0 without a response.
  final int status;

  /// Server-requested back-off (`Retry-After`, 429 only).
  final Duration? retryAfter;

  /// Whether the session is no longer valid and the user must sign in again.
  bool get isUnauthorized => status == 401;

  @override
  String toString() => 'ApiException($status, $code)';
}
