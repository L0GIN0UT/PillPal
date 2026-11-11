import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/export_dto.dart';
import '../../data/config.dart';
import '../../data/providers.dart';
import '../auth/auth_flow_state.dart';
import '../auth/auth_session.dart';
import 'export_files.dart';
import 'export_state.dart';
import 'file_sharer.dart';

export 'export_state.dart';

/// The export screen's controller: password step-up, asking for the archive,
/// polling until it is built, a single streamed download into the cache
/// directory, the share sheet, and deleting the file (ADR 0016 §8).
///
/// The archive is handed out once and claimed before its bytes are sent, so a
/// broken transfer is never repeated: the controller asks the status once and
/// either offers "check again" (the export is still `ready`) or a new request
/// (it is not). The file stays after a share, completed or not, so a target
/// that reads it lazily still can; it is deleted when the user leaves the
/// screen, when the app comes back to the foreground after the share
/// ([appResumed]), on any failure, at app start and on sign-out (owner
/// decision 2026-11-11).
///
/// Nothing here is logged: not the password, the export id, the path or any
/// content.
final exportControllerProvider =
    NotifierProvider.autoDispose<ExportController, ExportState>(
  ExportController.new,
);

/// Waits [delay] between two status checks; tests make it instant.
final exportDelayProvider = Provider<Future<void> Function(Duration)>(
  (ref) => (delay) => Future<void>.delayed(delay),
);

/// See [exportControllerProvider].
class ExportController extends AutoDisposeNotifier<ExportState> {
  String? _exportId;
  File? _file;
  bool _disposed = false;
  bool _starting = false;
  bool _notReadyHop = false;
  late final ExportFiles _files;

  @override
  ExportState build() {
    // Held now: a provider may not be read once it is disposed, and the
    // archive must still be deleted then.
    _files = ref.read(exportFilesProvider);
    ref.onDispose(() {
      _disposed = true;
      _exportId = null;
      _file = null;
      // The archive does not outlive the screen, shared or not.
      unawaited(_files.clear());
    });
    return const ExportState();
  }

  void _emit(ExportState next) {
    if (!_disposed) {
      state = next;
    }
  }

  /// Clears the shown error (the user edits the password).
  void clearError() {
    if (state.phase == ExportPhase.form && state.errorCode != null) {
      _emit(const ExportState());
    }
  }

  /// Back to the password step after a failure that a new request fixes.
  void restart() {
    if (state.phase == ExportPhase.failed || state.phase == ExportPhase.done) {
      _exportId = null;
      _emit(const ExportState());
    }
  }

  /// Asks for the export after the step-up with [password] and follows it to
  /// the share sheet. A wrong password stays on the form.
  Future<void> start(String password) async {
    // Synchronous: a second tap before the first await must not get through.
    if (state.busy || _starting) {
      return;
    }
    if (password.isEmpty) {
      _emit(const ExportState(errorCode: 'invalid_password'));
      return;
    }
    _starting = true;
    _notReadyHop = false;
    try {
      final userId = await _userId();
      if (_disposed) {
        return;
      }
      if (userId == null) {
        _emit(const ExportState(errorCode: AuthClientErrors.generic));
        return;
      }
      _emit(const ExportState(phase: ExportPhase.requesting));
      final api = ref.read(exportApiProvider);
      final export = await api.request(password, userId: userId);
      _exportId = export.id;
      await _follow(export, userId);
    } on ApiException catch (error) {
      await _requestFailed(error);
    } on FormatException {
      _emit(const ExportState(errorCode: ApiException.invalidResponse));
    } on Object {
      _unexpected();
    } finally {
      _starting = false;
    }
  }

  /// Checks the status of the export in hand once more and goes on from
  /// there (after "check again").
  Future<void> resume() async {
    final id = _exportId;
    if (state.busy || _starting || id == null) {
      return;
    }
    _starting = true;
    _notReadyHop = false;
    try {
      final userId = await _userId();
      if (userId == null || _disposed) {
        return;
      }
      _emit(const ExportState(phase: ExportPhase.building));
      final api = ref.read(exportApiProvider);
      final export = await api.status(id, userId: userId);
      await _follow(export, userId);
    } on ApiException catch (error) {
      await _failed(error.code, error: error, resumable: true);
    } on FormatException {
      _fail(ApiException.invalidResponse, resumable: true);
    } on Object {
      _unexpected(resumable: true);
    } finally {
      _starting = false;
    }
  }

  /// The app came back to the foreground: a shared archive is deleted now.
  /// The share is over, and the file must not wait for the screen to close.
  void appResumed() {
    if (state.phase == ExportPhase.done) {
      _file = null;
      unawaited(_files.clear());
    }
  }

  /// Offers the archive in hand to the share sheet. The file stays either way:
  /// after a closed sheet for another try, after a share for a target that
  /// reads it lazily.
  Future<void> share() async {
    final file = _file;
    if (file == null || state.sharing || state.phase != ExportPhase.ready) {
      return;
    }
    _emit(const ExportState(phase: ExportPhase.ready, sharing: true));
    ShareOutcome outcome;
    String? errorCode;
    try {
      outcome = await ref.read(archiveSharerProvider)(file);
    } on Object {
      outcome = ShareOutcome.notShared;
      errorCode = AuthClientErrors.generic;
    }
    if (_disposed) {
      return;
    }
    if (outcome == ShareOutcome.shared) {
      // The file stays: the target may still be reading it. Leaving the
      // screen, or the next foreground, deletes it.
      _exportId = null;
      _emit(const ExportState(phase: ExportPhase.done));
      return;
    }
    _emit(ExportState(phase: ExportPhase.ready, errorCode: errorCode));
  }

  Future<String?> _userId() => ref.read(syncStateStoreProvider).boundUserId();

  Future<void> _requestFailed(ApiException error) async {
    if (_disposed) {
      return;
    }
    if (error.isUnauthorized && error.code != 'invalid_password') {
      await ref.read(authSessionProvider.notifier).recheck();
    }
    _emit(ExportState(errorCode: error.code, retryAfter: error.retryAfter));
  }

  /// Goes on from the status of [export].
  Future<void> _follow(DataExport export, String userId) async {
    if (_disposed) {
      return;
    }
    switch (export.status) {
      case ExportStatus.ready:
        await _download(export, userId);
      case ExportStatus.queued:
      case ExportStatus.running:
        await _poll(userId);
      case ExportStatus.failed:
        _fail(export.errorCode ?? ExportErrors.buildFailed);
      case ExportStatus.downloaded:
      case ExportStatus.expired:
        _fail(ExportErrors.gone);
    }
  }

  Future<void> _poll(String userId) async {
    final id = _exportId;
    if (id == null) {
      return;
    }
    _emit(const ExportState(phase: ExportPhase.building));
    final wait = ref.read(exportDelayProvider);
    for (var attempt = 0; attempt < ExportPolicy.pollAttempts; attempt++) {
      await wait(ExportPolicy.pollInterval);
      if (_disposed) {
        return;
      }
      final DataExport export;
      try {
        export = await ref.read(exportApiProvider).status(id, userId: userId);
      } on ApiException catch (error) {
        await _failed(error.code, error: error, resumable: true);
        return;
      } on FormatException {
        _fail(ApiException.invalidResponse, resumable: true);
        return;
      } on Object {
        _unexpected(resumable: true);
        return;
      }
      if (export.status != ExportStatus.queued &&
          export.status != ExportStatus.running) {
        await _follow(export, userId);
        return;
      }
    }
    _fail(ExportClientErrors.stillBuilding, resumable: true);
  }

  Future<void> _download(DataExport export, String userId) async {
    _emit(const ExportState(phase: ExportPhase.downloading));
    final File file;
    try {
      file = await _files.create(
        ref.read(apiConfigProvider).region,
        export.readyAt ?? ref.read(clockProvider)(),
      );
    } on Object {
      // Nothing was claimed yet: the export is still there to fetch.
      _fail(ApiException.storageError, resumable: true);
      return;
    }
    if (_disposed) {
      return;
    }
    try {
      final api = ref.read(exportApiProvider);
      await api.downloadTo(export.id, file, userId: userId);
    } on ApiException catch (error) {
      await _downloadFailed(error, userId);
      return;
    } on Object {
      await _afterBrokenTransfer(ApiException.networkError, userId);
      return;
    }
    if (_disposed) {
      await _files.clear();
      return;
    }
    _file = file;
    _emit(const ExportState(phase: ExportPhase.ready));
    await share();
  }

  /// A failed download. The server's own answers are final; a transfer that
  /// broke after the claim asks the status once to learn whether the archive
  /// can still be fetched.
  Future<void> _downloadFailed(ApiException error, String userId) async {
    if (_disposed) {
      return;
    }
    if (error.code == ExportErrors.notReady) {
      // Once: a server that keeps saying "not ready" must not loop us.
      if (_notReadyHop) {
        _fail(ExportClientErrors.stillBuilding, resumable: true);
        return;
      }
      _notReadyHop = true;
      await _poll(userId);
      return;
    }
    if (error.code == ExportErrors.failed) {
      _fail(ExportErrors.failed);
      return;
    }
    // 410 after a download or the expiry; 404 for another session's export.
    if (error.code == ExportErrors.gone ||
        error.status == 410 ||
        error.status == 404) {
      _fail(ExportErrors.gone);
      return;
    }
    if (error.isUnauthorized || error.code == ApiException.accountChanged) {
      await _failed(error.code, error: error);
      return;
    }
    await _afterBrokenTransfer(error.code, userId);
  }

  Future<void> _afterBrokenTransfer(String code, String userId) async {
    final id = _exportId;
    if (id == null || _disposed) {
      return;
    }
    try {
      final export =
          await ref.read(exportApiProvider).status(id, userId: userId);
      switch (export.status) {
        case ExportStatus.ready:
          _fail(code, resumable: true);
        case ExportStatus.downloaded:
          _fail(ExportClientErrors.transferLost);
        case ExportStatus.failed:
          _fail(export.errorCode ?? ExportErrors.buildFailed);
        case ExportStatus.queued:
        case ExportStatus.running:
        case ExportStatus.expired:
          _fail(ExportErrors.gone);
      }
    } on ApiException {
      // The status cannot be had either: checking again is harmless, because
      // a claimed archive answers 410.
      _fail(code, resumable: true);
    } on Object {
      _fail(code, resumable: true);
    }
  }

  Future<void> _failed(
    String code, {
    required ApiException error,
    bool resumable = false,
  }) async {
    if (_disposed) {
      return;
    }
    if (error.isUnauthorized) {
      await ref.read(authSessionProvider.notifier).recheck();
    }
    _fail(code, resumable: resumable);
  }

  /// Anything that was not foreseen ends the flow in `failed`, never in a
  /// spinner, with the partial files deleted.
  void _unexpected({bool resumable = false}) =>
      _fail(AuthClientErrors.generic, resumable: resumable);

  void _fail(String code, {bool resumable = false}) {
    if (_disposed) {
      return;
    }
    unawaited(_files.clear());
    _file = null;
    _emit(
      ExportState(
        phase: ExportPhase.failed,
        errorCode: code,
        resumable: resumable,
      ),
    );
  }
}
