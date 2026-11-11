import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/data/api/export_dto.dart';
import 'package:pillpal/src/features/privacy/export_controller.dart';
import 'package:pillpal/src/features/privacy/export_files.dart';
import 'package:pillpal/src/features/privacy/file_sharer.dart';

import '../support/export_env.dart';
import '../support/export_server.dart';

// The export controller (ADR 0016 section 8): the share sheet, the file and a
// transfer that fails.

void main() {
  group('the share sheet and the file', () {
    test('a closed sheet keeps the file until the screen is left', () async {
      final env = await exportEnv();
      env.outcomes
        ..clear()
        ..add(ShareOutcome.notShared);

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.ready);
      expect(env.filesOnDisk, hasLength(1));

      env.screen.close();
      await pumpEventQueue();

      expect(env.filesOnDisk, isEmpty, reason: 'leaving deletes the archive');
    });

    test('after a share the file stays until the screen is left', () async {
      final env = await exportEnv();

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.done);
      expect(env.filesOnDisk, hasLength(1));

      env.screen.close();
      await pumpEventQueue();

      expect(env.filesOnDisk, isEmpty);
    });

    test('coming back to the app after a share deletes the file', () async {
      final env = await exportEnv();
      await env.controller.start(exportPassword);
      expect(env.filesOnDisk, hasLength(1));

      env.controller.appResumed();
      await pumpEventQueue();

      expect(env.filesOnDisk, isEmpty);
      expect(env.state.phase, ExportPhase.done);
    });

    test('coming back before anything was shared keeps the file', () async {
      final env = await exportEnv();
      env.outcomes
        ..clear()
        ..add(ShareOutcome.notShared);
      await env.controller.start(exportPassword);

      env.controller.appResumed();
      await pumpEventQueue();

      expect(env.state.phase, ExportPhase.ready);
      expect(env.filesOnDisk, hasLength(1));
    });

    test('sharing again after a closed sheet ends in done', () async {
      final env = await exportEnv();
      env.outcomes
        ..clear()
        ..addAll([ShareOutcome.notShared, ShareOutcome.shared]);

      await env.controller.start(exportPassword);
      expect(env.filesOnDisk, hasLength(1));
      await env.controller.share();

      expect(env.state.phase, ExportPhase.done);
      expect(env.shared, hasLength(2));
    });

    test('a share sheet that cannot open keeps the file and says so', () async {
      final env = await exportEnv();
      env.shareThrows = true;

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.ready);
      expect(env.state.errorCode, isNotNull);
      expect(env.filesOnDisk, hasLength(1));
    });
  });

  group('a transfer that fails', () {
    test('after the claim: one attempt, then one status check says it is lost',
        () async {
      final server = FakeExportServer()..breakAfterClaim = true;
      final env = await exportEnv(server: server);

      await env.controller.start(exportPassword);

      expect(
        env.server.downloads,
        1,
        reason: 'a claimed archive is never retried',
      );
      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.errorCode, ExportClientErrors.transferLost);
      expect(env.state.resumable, isFalse);
      expect(env.filesOnDisk, isEmpty);
      expect(env.server.calls.last, 'GET /v1/me/export/$fakeExportId');
    });

    test('before the claim: the export is still ready, so check again works',
        () async {
      final server = FakeExportServer()..breakBeforeClaim = true;
      final env = await exportEnv(server: server);

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.errorCode, 'network_error');
      expect(env.state.resumable, isTrue);
      expect(env.server.downloads, 1);

      server.breakBeforeClaim = false;
      await env.controller.resume();

      expect(env.state.phase, ExportPhase.done);
      expect(env.shared, [fakeArchiveBytes]);
    });

    test('when the status cannot be had either, checking again is offered',
        () async {
      final server = FakeExportServer()..status = 'ready';
      final env = await exportEnv(server: server);
      server.onDownload = () async {
        server.statusFailure = (500, 'internal');
        throw http.ClientException('connection lost');
      };

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.resumable, isTrue);
    });

    test('410 is final: no status check, a new request is needed', () async {
      final server = FakeExportServer()..status = 'ready';
      final env = await exportEnv(server: server);
      server.onDownload = () async => exportFailure(410, 'export_gone');

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.errorCode, ExportErrors.gone);
      expect(env.state.resumable, isFalse);
      expect(env.server.statusChecks, 0);
    });

    test('a failed export is final too', () async {
      final server = FakeExportServer()..status = 'ready';
      final env = await exportEnv(server: server);
      server.onDownload = () async => exportFailure(409, 'export_failed');

      await env.controller.start(exportPassword);

      expect(env.state.errorCode, ExportErrors.failed);
      expect(env.state.resumable, isFalse);
    });

    test('a 404 (another session) is final and says gone', () async {
      final server = FakeExportServer()..status = 'ready';
      final env = await exportEnv(server: server);
      server.onDownload = () async => exportFailure(404, 'not_found');

      await env.controller.start(exportPassword);

      expect(env.state.errorCode, ExportErrors.gone);
      expect(env.state.resumable, isFalse);
    });

    test('not ready yet goes back to waiting', () async {
      final server = FakeExportServer()..status = 'ready';
      final env = await exportEnv(server: server);
      var first = true;
      server.onDownload = () async {
        if (first) {
          first = false;
          server.status = 'queued';
          return exportFailure(409, 'export_not_ready');
        }
        return http.Response.bytes(fakeArchiveBytes, 200);
      };
      server.readyAfterPolls = 1;

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.done);
      expect(env.server.downloads, 2);
    });

    test('a file that cannot be created is a storage failure to retry',
        () async {
      final server = FakeExportServer()..status = 'ready';
      final env = await exportEnv(
        server: server,
        files: ExportFiles(() async => throw const FileSystemException()),
      );

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.errorCode, 'storage_error');
      expect(env.state.resumable, isTrue);
      expect(env.state.mustStay, isFalse, reason: 'the screen can be left');
      expect(env.server.downloads, 0, reason: 'nothing was claimed');
    });

    test('an unexpected error in the transfer ends in failed, not a spinner',
        () async {
      final server = FakeExportServer()..status = 'ready';
      final env = await exportEnv(server: server);
      server.onDownload = () async => throw StateError('unexpected');

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.mustStay, isFalse);
      expect(env.filesOnDisk, isEmpty);
      expect(env.state.resumable, isTrue, reason: 'the status says ready');
    });

    test('an unexpected error while asking ends in failed too', () async {
      final server = FakeExportServer();
      final env = await exportEnv(server: server);
      server.onRequest = () => throw StateError('unexpected');

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.errorCode, 'generic');
    });

    test('not ready is followed once, then it offers to check again', () async {
      final server = FakeExportServer()..status = 'ready';
      final env = await exportEnv(server: server);
      server.onDownload = () async {
        server.status = 'queued';
        return exportFailure(409, 'export_not_ready');
      };

      await env.controller.start(exportPassword);

      expect(env.server.downloads, 2, reason: 'one hop, not a loop');
      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.errorCode, 'export_still_building');
      expect(env.state.resumable, isTrue);
    });

    test('restart returns to the password step for a new request', () async {
      final server = FakeExportServer()..status = 'expired';
      final env = await exportEnv(server: server);
      await env.controller.start(exportPassword);
      expect(env.state.phase, ExportPhase.failed);

      env.controller.restart();

      expect(env.state.phase, ExportPhase.form);
      expect(env.state.errorCode, isNull);
    });
  });

  group('leaving the screen', () {
    test('while waiting stops the polling and leaves nothing behind', () async {
      final env = await exportEnv();
      final gate = Completer<void>();
      env.wait = (_) => gate.future;

      final running = env.controller.start(exportPassword);
      await pumpEventQueue();
      env.screen.close();
      await pumpEventQueue();
      gate.complete();
      await running;

      expect(env.server.statusChecks, 0);
      expect(env.server.downloads, 0);
      expect(env.filesOnDisk, isEmpty);
    });

    test('during the download deletes the archive when it arrives', () async {
      final server = FakeExportServer()..status = 'ready';
      final env = await exportEnv(server: server);
      server.holdDownload = Completer<void>();

      final running = env.controller.start(exportPassword);
      await pumpEventQueue();
      env.screen.close();
      await pumpEventQueue();
      server.holdDownload!.complete();
      await running;
      await pumpEventQueue();

      expect(env.shared, isEmpty, reason: 'nobody is looking: no share sheet');
      expect(env.filesOnDisk, isEmpty);
    });
  });
}
