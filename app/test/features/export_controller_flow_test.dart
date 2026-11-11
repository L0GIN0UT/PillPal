import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/export_dto.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/features/auth/auth_session.dart';
import 'package:pillpal/src/features/privacy/export_controller.dart';

import '../support/export_env.dart';
import '../support/export_server.dart';

// The export controller (ADR 0016 section 8): the password step-up and polling.

void main() {
  group('the whole flow', () {
    test('requests, waits, downloads and shares the archive', () async {
      final env = await exportEnv();
      final phases = <ExportPhase>[];
      env.container.listen(
        exportControllerProvider,
        (_, next) => phases.add(next.phase),
      );

      await env.controller.start(exportPassword);

      expect(
        phases.toSet().toList(),
        [
          ExportPhase.requesting,
          ExportPhase.building,
          ExportPhase.downloading,
          ExportPhase.ready,
          ExportPhase.done,
        ],
      );
      expect(env.shared, [fakeArchiveBytes]);
      expect(
        env.filesOnDisk,
        hasLength(1),
        reason: 'kept until the screen is left: a target may still read it',
      );
      expect(env.delays, [ExportPolicy.pollInterval]);
      expect(env.server.calls, [
        'POST /v1/me/export',
        'GET /v1/me/export/$fakeExportId',
        'POST /v1/me/export/$fakeExportId/download',
      ]);
    });

    test(
        'the request carries only the password; the file is named by region '
        'and date', () async {
      final env = await exportEnv();

      await env.controller.start(exportPassword);

      expect(env.sharedNames, ['pillpal-export-ru-20261111.zip']);
      expect(env.server.requests.first.body, '{"password":"$exportPassword"}');
    });

    test('a replay (200) is followed like a new request', () async {
      final server = FakeExportServer()
        ..requestIsReplay = true
        ..status = 'ready';
      final env = await exportEnv(server: server);

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.done);
      expect(env.server.statusChecks, 0, reason: 'ready: no need to wait');
      expect(env.delays, isEmpty);
    });

    test('two taps before the first answer send one request', () async {
      final env = await exportEnv();

      final first = env.controller.start(exportPassword);
      final second = env.controller.start(exportPassword);
      await Future.wait([first, second]);

      expect(env.server.count('/v1/me/export'), 1);
      expect(env.state.phase, ExportPhase.done);
    });

    test('a second start while one is running is ignored', () async {
      final env = await exportEnv();
      final gate = Completer<void>();
      env.wait = (_) => gate.future;

      final first = env.controller.start(exportPassword);
      await pumpEventQueue();
      await env.controller.start(exportPassword);
      gate.complete();
      await first;

      expect(env.server.count('/v1/me/export'), 1);
    });
  });

  group('the password step-up', () {
    test('a wrong password stays on the form and asks nothing more', () async {
      final env = await exportEnv();

      await env.controller.start('wrong-pass');

      expect(env.state.phase, ExportPhase.form);
      expect(env.state.errorCode, 'invalid_password');
      expect(env.server.calls, ['POST /v1/me/export']);

      await env.controller.start(exportPassword);
      expect(env.state.phase, ExportPhase.done);
    });

    test('an empty password is refused without a request', () async {
      final env = await exportEnv();

      await env.controller.start('');

      expect(env.state.errorCode, 'invalid_password');
      expect(env.server.requests, isEmpty);
    });

    test('the cooldown is a 429 with the wait the server asks for', () async {
      final server = FakeExportServer()
        ..requestFailure = (429, ExportErrors.rateLimited)
        ..retryAfterSeconds = 1800;
      final env = await exportEnv(server: server);

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.form);
      expect(env.state.errorCode, ExportErrors.rateLimited);
      expect(env.state.retryAfter, const Duration(minutes: 30));
    });

    test('the flag being off is shown on the form', () async {
      final server = FakeExportServer()
        ..requestFailure = (403, ExportErrors.featureDisabled);
      final env = await exportEnv(server: server);

      await env.controller.start(exportPassword);

      expect(env.state.errorCode, ExportErrors.featureDisabled);
    });

    test('a server error on the request can be tried again', () async {
      final server = FakeExportServer();
      final env = await exportEnv(server: server);
      server.requestFailure = (500, 'internal_error');
      await env.controller.start(exportPassword);
      expect(env.state.phase, ExportPhase.form);
      expect(env.state.errorCode, 'internal_error');

      server.requestFailure = null;
      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.done);
    });

    test('editing the password clears the error', () async {
      final env = await exportEnv();
      await env.controller.start('wrong-pass');

      env.controller.clearError();

      expect(env.state.errorCode, isNull);
    });
  });

  group('polling', () {
    test('keeps asking while the export is queued or running', () async {
      final server = FakeExportServer()..readyAfterPolls = 4;
      final env = await exportEnv(server: server);

      await env.controller.start(exportPassword);

      expect(env.server.statusChecks, 4);
      expect(env.delays, hasLength(4));
      expect(env.state.phase, ExportPhase.done);
    });

    test('stops on a failed build and shows its code', () async {
      final server = FakeExportServer()
        ..status = 'failed'
        ..errorCode = ExportErrors.tooLarge;
      final env = await exportEnv(server: server);

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.errorCode, ExportErrors.tooLarge);
      expect(env.state.resumable, isFalse);
      expect(env.server.downloads, 0);
    });

    test('a build that failed without a code is a build failure', () async {
      final server = FakeExportServer()..status = 'failed';
      final env = await exportEnv(server: server);

      await env.controller.start(exportPassword);

      expect(env.state.errorCode, ExportErrors.buildFailed);
    });

    test('stops on an expired export: a new one must be requested', () async {
      final server = FakeExportServer()..status = 'expired';
      final env = await exportEnv(server: server);

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.errorCode, ExportErrors.gone);
      expect(env.state.resumable, isFalse);
    });

    test('a build that takes too long offers to check again', () async {
      final server = FakeExportServer()..readyAfterPolls = 1000000;
      final env = await exportEnv(server: server);

      await env.controller.start(exportPassword);

      expect(env.server.statusChecks, ExportPolicy.pollAttempts);
      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.errorCode, ExportClientErrors.stillBuilding);
      expect(env.state.resumable, isTrue);

      server.status = 'ready';
      await env.controller.resume();

      expect(env.state.phase, ExportPhase.done);
      expect(env.server.downloads, 1);
    });

    test('a status check that fails can be resumed', () async {
      final server = FakeExportServer()..statusFailure = (500, 'internal');
      final env = await exportEnv(server: server);

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.resumable, isTrue);

      server.statusFailure = null;
      await env.controller.resume();
      expect(env.state.phase, ExportPhase.done);
    });

    test('a session that ended while waiting signs the app out', () async {
      final server = FakeExportServer()..statusFailure = (401, 'invalid_token');
      final env = await exportEnv(server: server);

      await env.controller.start(exportPassword);

      expect(env.state.phase, ExportPhase.failed);
      expect(await env.container.read(authSessionProvider.future), isFalse);
    });
  });
}
