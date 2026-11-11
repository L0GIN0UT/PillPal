import 'package:flutter/foundation.dart';

import '../../data/api/export_dto.dart';
import '../auth/auth_flow_state.dart';

/// Where the export of the account is, as the screen shows it.
enum ExportPhase {
  /// Nothing asked yet: the password step-up.
  form,

  /// The request is in flight.
  requesting,

  /// The server builds the archive; the app asks its status.
  building,

  /// The archive is being streamed to the device.
  downloading,

  /// The archive is on the device, to be shared (a first share ended without
  /// a target, or has not been started).
  ready,

  /// The archive was shared; the file is deleted when the screen is left (or
  /// the app comes back to the foreground).
  done,

  /// Something failed: see [ExportState.errorCode].
  failed,
}

/// State of the export screen. It never holds the password, the export id or
/// the file: the controller keeps the id and the file in private fields.
@immutable
class ExportState {
  /// Creates a state.
  const ExportState({
    this.phase = ExportPhase.form,
    this.errorCode,
    this.retryAfter,
    this.resumable = false,
    this.sharing = false,
  });

  /// Current phase.
  final ExportPhase phase;

  /// Error of the last action (server, [ExportClientErrors] or
  /// [AuthClientErrors] code). In [ExportPhase.form] it is the error of a
  /// request (a wrong password, the cooldown); in [ExportPhase.ready] a share
  /// sheet that failed to open.
  final String? errorCode;

  /// The wait the server asks for after `export_rate_limited`.
  final Duration? retryAfter;

  /// After a failure: the same export can still be followed (a status check
  /// decides), as opposed to a new one that must be requested.
  final bool resumable;

  /// The share sheet is open.
  final bool sharing;

  /// A request is in flight and the password field must not be used again.
  bool get busy =>
      phase == ExportPhase.requesting ||
      phase == ExportPhase.building ||
      phase == ExportPhase.downloading;

  /// Leaving now would lose the archive: its claim is committed.
  bool get mustStay => phase == ExportPhase.downloading;
}
