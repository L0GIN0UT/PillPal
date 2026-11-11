import 'json.dart';

// Wire forms of the data export (backend/app/schemas/exports.py, ADR 0016 §8,
// docs/spec/export.md).

/// Where an export is (`ExportOut.status`).
enum ExportStatus {
  /// Waiting for the worker.
  queued('queued'),

  /// Being built.
  running('running'),

  /// Built; the archive can be downloaded once.
  ready('ready'),

  /// The archive was handed out (or its claim committed); it is gone.
  downloaded('downloaded'),

  /// The build failed; see [DataExport.errorCode].
  failed('failed'),

  /// Not downloaded within its window; it is gone.
  expired('expired');

  const ExportStatus(this.wire);

  /// Value on the wire.
  final String wire;

  /// The status with wire value [wire], or null for one this app does not
  /// know.
  static ExportStatus? tryParse(String wire) {
    for (final status in values) {
      if (status.wire == wire) {
        return status;
      }
    }
    return null;
  }
}

/// Error codes of the export endpoints the app reacts to.
abstract final class ExportErrors {
  /// A new request within the cooldown of one that was not downloaded (429,
  /// with `Retry-After`).
  static const String rateLimited = 'export_rate_limited';

  /// The archive is over the server's size cap (`ExportOut.error_code`).
  static const String tooLarge = 'export_too_large';

  /// The build failed (`ExportOut.error_code`).
  static const String buildFailed = 'export_build_failed';

  /// Downloaded or expired (410 on download).
  static const String gone = 'export_gone';

  /// The archive is not built yet (409 on download).
  static const String notReady = 'export_not_ready';

  /// The build failed (409 on download).
  static const String failed = 'export_failed';

  /// The export is switched off on this server (403).
  static const String featureDisabled = 'feature_disabled';
}

/// Client-side export outcomes that have no server code.
abstract final class ExportClientErrors {
  /// The archive was claimed, but its bytes did not arrive: the export is
  /// lost and a new one must be requested.
  static const String transferLost = 'export_transfer_lost';

  /// The build is still running after the app stopped waiting.
  static const String stillBuilding = 'export_still_building';
}

/// What an export id looks like; it goes into a request path, so anything
/// else is refused.
final RegExp exportIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// One export of the account (`ExportOut`). Never logged: the id is the
/// handle of the most concentrated medical artefact the system makes.
class DataExport {
  /// Creates an export.
  const DataExport({
    required this.id,
    required this.status,
    required this.requestedAt,
    this.readyAt,
    this.expiresAt,
    this.sizeBytes,
    this.errorCode,
  });

  /// Parses `ExportOut`. A status this app does not know is a
  /// [FormatException]: it cannot say what to do next.
  factory DataExport.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    final id = reader.string('id');
    if (!exportIdPattern.hasMatch(id)) {
      // The id goes into a request path.
      throw const FormatException('Expected a UUID at "id"');
    }
    final status = ExportStatus.tryParse(reader.string('status'));
    if (status == null) {
      throw const FormatException('Unknown export status');
    }
    return DataExport(
      id: id,
      status: status,
      requestedAt: reader.instant('requested_at'),
      readyAt: reader.instantOrNull('ready_at'),
      expiresAt: reader.instantOrNull('expires_at'),
      sizeBytes: reader.integerOrNull('size_bytes'),
      errorCode: reader.stringOrNull('error_code'),
    );
  }

  /// Keys read from `ExportOut`.
  static const Set<String> readKeys = {
    'id',
    'status',
    'requested_at',
    'ready_at',
    'expires_at',
    'size_bytes',
    'error_code',
  };

  /// Opaque export id.
  final String id;

  /// Where the export is.
  final ExportStatus status;

  /// When it was asked for.
  final DateTime requestedAt;

  /// When the archive became ready.
  final DateTime? readyAt;

  /// Until when the archive can be downloaded, once.
  final DateTime? expiresAt;

  /// Size of the zip.
  final int? sizeBytes;

  /// `export_too_large` or `export_build_failed` for a failed export.
  final String? errorCode;
}

/// Request bodies of the export endpoints.
abstract final class ExportBodies {
  /// `ExportRequest` with the password step-up (the app has no other sign-in
  /// provider yet, so the `reauth` form is never sent).
  static JsonMap request(String password) => {'password': password};
}
