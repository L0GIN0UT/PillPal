import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../data/db/database.dart';
import 'report_history.dart';

/// What came of a file action.
enum ReportActionResult {
  /// Done: opened, saved, or handed to the share sheet.
  done,

  /// The person closed the system picker without saving.
  cancelled,

  /// No app on the device can show a PDF (open only).
  noApp,

  /// Another action is still waiting for the system; nothing was done.
  busy,
}

/// Opens, saves or shares a stored report (docs/adr/0019 §5). The file leaves
/// the app's control the moment the system is offered the file by one of these: the sheet says so.
abstract interface class ReportActions {
  /// Shows [report] in a PDF viewer.
  Future<ReportActionResult> open(StoredReport report);

  /// Lets the person pick where to save a copy of [report].
  Future<ReportActionResult> save(StoredReport report);

  /// Hands [report] to the system share sheet.
  Future<ReportActionResult> share(StoredReport report);
}

/// The platform channel of the Android side (`ReportChannel.kt`).
const MethodChannel reportChannel = MethodChannel('pillpal/reports');

/// How long a save may wait for the system picker and the copy before the
/// call fails, so that a lost native answer can never hang the sheet.
const Duration reportSaveTimeout = Duration(minutes: 10);

/// [ReportActions] over `pillpal/reports` (Android): `ACTION_VIEW`,
/// `ACTION_CREATE_DOCUMENT` and `ACTION_SEND` through a FileProvider. Only
/// the absolute path of the stored file crosses the channel; the native side
/// accepts nothing outside its private `files/reports` folder.
class ChannelReportActions implements ReportActions {
  /// Creates the actions over [_channel] and [_history].
  const ChannelReportActions(
    this._channel,
    this._history, {
    this.saveTimeout = reportSaveTimeout,
  });

  /// Longest wait for a save.
  final Duration saveTimeout;

  final MethodChannel _channel;
  final ReportHistory _history;

  @override
  Future<ReportActionResult> open(StoredReport report) => _call('open', report);

  @override
  Future<ReportActionResult> save(StoredReport report) =>
      _call('saveAs', report);

  @override
  Future<ReportActionResult> share(StoredReport report) =>
      _call('share', report);

  Future<ReportActionResult> _call(String method, StoredReport report) async {
    final file = await _history.fileOf(report);
    try {
      var call = _channel.invokeMethod<String>(
        method,
        <String, Object?>{'path': file.path},
      );
      if (method == 'saveAs') {
        call = call.timeout(saveTimeout);
      }
      return switch (await call) {
        'done' => ReportActionResult.done,
        'cancelled' => ReportActionResult.cancelled,
        'no_app' => ReportActionResult.noApp,
        // An unknown answer is a failure, never a success.
        _ => throw StateError('Unexpected answer of the report channel'),
      };
    } on PlatformException catch (error) {
      if (error.code == 'busy') {
        return ReportActionResult.busy;
      }
      rethrow;
    }
  }
}

/// [ReportActions] over `printing`, for platforms without the channel (iOS):
/// all three go to the share sheet, which offers Files, Print and apps.
class PrintingReportActions implements ReportActions {
  /// Creates the fallback over [_history].
  const PrintingReportActions(this._history);

  final ReportHistory _history;

  @override
  Future<ReportActionResult> open(StoredReport report) => share(report);

  @override
  Future<ReportActionResult> save(StoredReport report) => share(report);

  @override
  Future<ReportActionResult> share(StoredReport report) async {
    final file = await _history.fileOf(report);
    await Printing.sharePdf(
      bytes: await file.readAsBytes(),
      filename: file.uri.pathSegments.last,
    );
    return ReportActionResult.done;
  }
}

/// The file actions of this platform (tests override it with a fake).
final reportActionsProvider = Provider<ReportActions>((ref) {
  final history = ref.watch(reportHistoryProvider);
  return defaultTargetPlatform == TargetPlatform.android
      ? ChannelReportActions(reportChannel, history)
      : PrintingReportActions(history);
});
