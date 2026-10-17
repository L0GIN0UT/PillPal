/// A failed API call: the server's stable error `code` and HTTP [status].
///
/// [status] is 0 when no HTTP response was received. The server's message is
/// not kept: the app localizes [code] (see `backend/app/errors.py`).
class ApiException implements Exception {
  /// Creates an exception.
  const ApiException(
    this.code,
    this.status, {
    this.retryAfter,
    this.details,
  });

  /// No response: offline, DNS, TLS or timeout.
  static const String networkError = 'network_error';

  /// A response the client cannot interpret.
  static const String invalidResponse = 'invalid_response';

  /// No stored session (signed out).
  static const String unauthorized = 'unauthorized';

  /// The stored session belongs to another account than the request's data.
  static const String accountChanged = 'account_changed';

  /// Another runner (isolate) kept the sync lease for the whole wait.
  static const String syncBusy = 'sync_busy';

  /// The sync lease lapsed during the call: its result was discarded.
  static const String leaseLost = 'lease_lost';

  /// Stable error code, e.g. `email_not_verified`, `rate_limited`.
  final String code;

  /// HTTP status, or 0 without a response.
  final int status;

  /// Server-requested back-off (`Retry-After`, 429 only).
  final Duration? retryAfter;

  /// Server-generated values of the error envelope's optional `details`
  /// (`account_pending_deletion`: `restore_ticket`, `erase_after`); never
  /// printed or logged, [toString] shows the code only.
  final Map<String, Object?>? details;

  /// Whether the session is no longer valid and the user must sign in again.
  bool get isUnauthorized => status == 401;

  @override
  String toString() => 'ApiException($status, $code)';
}
