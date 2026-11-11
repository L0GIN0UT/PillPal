import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/data/api/export_dto.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/auth/auth_session.dart';
import 'package:pillpal/src/features/privacy/export_controller.dart';
import 'package:pillpal/src/features/privacy/file_sharer.dart';

import '../helpers.dart';
import '../support/export_server.dart';

// The export controller (ADR 0016 §8): password step-up, polling, a single
// streamed download, the share sheet and the deletion of the archive.

const String _user = 'user-1';
const String _password = 'correct-pass';

class _Env {
  _Env(this.server, this.harness, this.container, this.screen);

  final FakeExportServer server;
  final TestHarness harness;
  final ProviderContainer container;

  /// The open screen: it keeps the controller alive; closing it leaves.
  final ProviderSubscription<ExportState> screen;

  /// What each share saw: the bytes of the file at that moment.
  final List<List<int>> shared = [];

  /// The names of the files that were offered to the share sheet.
  final List<String> sharedNames = [];

  /// The waits the controller asked for.
  final List<Duration> delays = [];

  /// Result of the next share sheets, in order; the last one repeats.
  final List<ShareOutcome> outcomes = [ShareOutcome.shared];

  /// The share sheet cannot open.
  bool shareThrows = false;

  /// Holds each wait between two status checks while set.
  Future<void> Function(Duration)? wait;

  ExportController get controller =>
      container.read(exportControllerProvider.notifier);

  ExportState get state => container.read(exportControllerProvider);

  List<File> get filesOnDisk => harness.tempDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.contains('pillpal-export-'))
      .toList();
}

/// A signed-in account with the export screen open: the controller lives
/// until [_Env.screen] is closed.
Future<_Env> _env({FakeExportServer? server}) async {
  final fake = server ?? FakeExportServer();
  final harness = TestHarness(handler: fake.handle);
  late final _Env env;
  final container = createContainer(
    harness,
    overrides: [
      exportDelayProvider.overrideWithValue((delay) async {
        env.delays.add(delay);
        await env.wait?.call(delay);
      }),
      archiveSharerProvider.overrideWithValue((file) async {
        if (env.shareThrows) {
          throw StateError('no share target');
        }
        env.shared.add(await file.readAsBytes());
        env.sharedNames.add(file.uri.pathSegments.last);
        return env.outcomes.length > 1
            ? env.outcomes.removeAt(0)
            : env.outcomes.single;
      }),
    ],
  );
  await container.read(syncStateStoreProvider).bindAccount(_user, 'ru');
  expect(await container.read(authSessionProvider.future), isTrue);
  final screen = container.listen(exportControllerProvider, (_, __) {});
  addTearDown(screen.close);
  env = _Env(fake, harness, container, screen);
  return env;
}

http.Response _failure(int status, String code) => http.Response(
      '{"error": {"code": "$code", "message": "synthetic"}}',
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('the whole flow', () {
    test('requests, waits, downloads, shares and deletes the archive',
        () async {
      final env = await _env();
      final phases = <ExportPhase>[];
      env.container.listen(
        exportControllerProvider,
        (_, next) => phases.add(next.phase),
      );

      await env.controller.start(_password);

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
      expect(env.filesOnDisk, isEmpty, reason: 'deleted after sharing');
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
      final env = await _env();

      await env.controller.start(_password);

      expect(env.sharedNames, ['pillpal-export-ru-20261111.zip']);
      expect(env.server.requests.first.body, '{"password":"$_password"}');
    });

    test('a replay (200) is followed like a new request', () async {
      final server = FakeExportServer()
        ..requestIsReplay = true
        ..status = 'ready';
      final env = await _env(server: server);

      await env.controller.start(_password);

      expect(env.state.phase, ExportPhase.done);
      expect(env.server.statusChecks, 0, reason: 'ready: no need to wait');
      expect(env.delays, isEmpty);
    });

    test('a second start while one is running is ignored', () async {
      final env = await _env();
      final gate = Completer<void>();
      env.wait = (_) => gate.future;

      final first = env.controller.start(_password);
      await pumpEventQueue();
      await env.controller.start(_password);
      gate.complete();
      await first;

      expect(env.server.count('/v1/me/export'), 1);
    });
  });

  group('the password step-up', () {
    test('a wrong password stays on the form and asks nothing more', () async {
      final env = await _env();

      await env.controller.start('wrong-pass');

      expect(env.state.phase, ExportPhase.form);
      expect(env.state.errorCode, 'invalid_password');
      expect(env.server.calls, ['POST /v1/me/export']);

      await env.controller.start(_password);
      expect(env.state.phase, ExportPhase.done);
    });

    test('an empty password is refused without a request', () async {
      final env = await _env();

      await env.controller.start('');

      expect(env.state.errorCode, 'invalid_password');
      expect(env.server.requests, isEmpty);
    });

    test('the cooldown is a 429 with the wait the server asks for', () async {
      final server = FakeExportServer()
        ..requestFailure = (429, ExportErrors.rateLimited)
        ..retryAfterSeconds = 1800;
      final env = await _env(server: server);

      await env.controller.start(_password);

      expect(env.state.phase, ExportPhase.form);
      expect(env.state.errorCode, ExportErrors.rateLimited);
      expect(env.state.retryAfter, const Duration(minutes: 30));
    });

    test('the flag being off is shown on the form', () async {
      final server = FakeExportServer()
        ..requestFailure = (403, ExportErrors.featureDisabled);
      final env = await _env(server: server);

      await env.controller.start(_password);

      expect(env.state.errorCode, ExportErrors.featureDisabled);
    });

    test('a server error on the request can be tried again', () async {
      final server = FakeExportServer();
      final env = await _env(server: server);
      server.requestFailure = (500, 'internal_error');
      await env.controller.start(_password);
      expect(env.state.phase, ExportPhase.form);
      expect(env.state.errorCode, 'internal_error');

      server.requestFailure = null;
      await env.controller.start(_password);

      expect(env.state.phase, ExportPhase.done);
    });

    test('editing the password clears the error', () async {
      final env = await _env();
      await env.controller.start('wrong-pass');

      env.controller.clearError();

      expect(env.state.errorCode, isNull);
    });
  });

  group('polling', () {
    test('keeps asking while the export is queued or running', () async {
      final server = FakeExportServer()..readyAfterPolls = 4;
      final env = await _env(server: server);

      await env.controller.start(_password);

      expect(env.server.statusChecks, 4);
      expect(env.delays, hasLength(4));
      expect(env.state.phase, ExportPhase.done);
    });

    test('stops on a failed build and shows its code', () async {
      final server = FakeExportServer()
        ..status = 'failed'
        ..errorCode = ExportErrors.tooLarge;
      final env = await _env(server: server);

      await env.controller.start(_password);

      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.errorCode, ExportErrors.tooLarge);
      expect(env.state.resumable, isFalse);
      expect(env.server.downloads, 0);
    });

    test('a build that failed without a code is a build failure', () async {
      final server = FakeExportServer()..status = 'failed';
      final env = await _env(server: server);

      await env.controller.start(_password);

      expect(env.state.errorCode, ExportErrors.buildFailed);
    });

    test('stops on an expired export: a new one must be requested', () async {
      final server = FakeExportServer()..status = 'expired';
      final env = await _env(server: server);

      await env.controller.start(_password);

      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.errorCode, ExportErrors.gone);
      expect(env.state.resumable, isFalse);
    });

    test('a build that takes too long offers to check again', () async {
      final server = FakeExportServer()..readyAfterPolls = 1000000;
      final env = await _env(server: server);

      await env.controller.start(_password);

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
      final env = await _env(server: server);

      await env.controller.start(_password);

      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.resumable, isTrue);

      server.statusFailure = null;
      await env.controller.resume();
      expect(env.state.phase, ExportPhase.done);
    });

    test('a session that ended while waiting signs the app out', () async {
      final server = FakeExportServer()..statusFailure = (401, 'invalid_token');
      final env = await _env(server: server);

      await env.controller.start(_password);

      expect(env.state.phase, ExportPhase.failed);
      expect(await env.container.read(authSessionProvider.future), isFalse);
    });
  });

  group('the share sheet and the file', () {
    test('a closed sheet keeps the file until the screen is left', () async {
      final env = await _env();
      env.outcomes
        ..clear()
        ..add(ShareOutcome.notShared);

      await env.controller.start(_password);

      expect(env.state.phase, ExportPhase.ready);
      expect(env.filesOnDisk, hasLength(1));

      env.screen.close();
      await pumpEventQueue();

      expect(env.filesOnDisk, isEmpty, reason: 'leaving deletes the archive');
    });

    test('sharing again after a closed sheet deletes the file', () async {
      final env = await _env();
      env.outcomes
        ..clear()
        ..addAll([ShareOutcome.notShared, ShareOutcome.shared]);

      await env.controller.start(_password);
      expect(env.filesOnDisk, hasLength(1));
      await env.controller.share();

      expect(env.state.phase, ExportPhase.done);
      expect(env.filesOnDisk, isEmpty);
      expect(env.shared, hasLength(2));
    });

    test('a share sheet that cannot open keeps the file and says so', () async {
      final env = await _env();
      env.shareThrows = true;

      await env.controller.start(_password);

      expect(env.state.phase, ExportPhase.ready);
      expect(env.state.errorCode, isNotNull);
      expect(env.filesOnDisk, hasLength(1));
    });
  });

  group('a transfer that fails', () {
    test('after the claim: one attempt, then one status check says it is lost',
        () async {
      final server = FakeExportServer()..breakAfterClaim = true;
      final env = await _env(server: server);

      await env.controller.start(_password);

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
      final env = await _env(server: server);

      await env.controller.start(_password);

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
      final env = await _env(server: server);
      server.onDownload = () async {
        server.statusFailure = (500, 'internal');
        throw http.ClientException('connection lost');
      };

      await env.controller.start(_password);

      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.resumable, isTrue);
    });

    test('410 is final: no status check, a new request is needed', () async {
      final server = FakeExportServer()..status = 'ready';
      final env = await _env(server: server);
      server.onDownload = () async => _failure(410, 'export_gone');

      await env.controller.start(_password);

      expect(env.state.phase, ExportPhase.failed);
      expect(env.state.errorCode, ExportErrors.gone);
      expect(env.state.resumable, isFalse);
      expect(env.server.statusChecks, 0);
    });

    test('a failed export is final too', () async {
      final server = FakeExportServer()..status = 'ready';
      final env = await _env(server: server);
      server.onDownload = () async => _failure(409, 'export_failed');

      await env.controller.start(_password);

      expect(env.state.errorCode, ExportErrors.failed);
      expect(env.state.resumable, isFalse);
    });

    test('a 404 (another session) is final and says gone', () async {
      final server = FakeExportServer()..status = 'ready';
      final env = await _env(server: server);
      server.onDownload = () async => _failure(404, 'not_found');

      await env.controller.start(_password);

      expect(env.state.errorCode, ExportErrors.gone);
      expect(env.state.resumable, isFalse);
    });

    test('not ready yet goes back to waiting', () async {
      final server = FakeExportServer()..status = 'ready';
      final env = await _env(server: server);
      var first = true;
      server.onDownload = () async {
        if (first) {
          first = false;
          server.status = 'queued';
          return _failure(409, 'export_not_ready');
        }
        return http.Response.bytes(fakeArchiveBytes, 200);
      };
      server.readyAfterPolls = 1;

      await env.controller.start(_password);

      expect(env.state.phase, ExportPhase.done);
      expect(env.server.downloads, 2);
    });

    test('restart returns to the password step for a new request', () async {
      final server = FakeExportServer()..status = 'expired';
      final env = await _env(server: server);
      await env.controller.start(_password);
      expect(env.state.phase, ExportPhase.failed);

      env.controller.restart();

      expect(env.state.phase, ExportPhase.form);
      expect(env.state.errorCode, isNull);
    });
  });

  group('leaving the screen', () {
    test('while waiting stops the polling and leaves nothing behind', () async {
      final env = await _env();
      final gate = Completer<void>();
      env.wait = (_) => gate.future;

      final running = env.controller.start(_password);
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
      final env = await _env(server: server);
      server.holdDownload = Completer<void>();

      final running = env.controller.start(_password);
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

  test('nothing about the export is logged', () async {
    final logs = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    addTearDown(() => debugPrint = previous);
    final env = await _env();

    await runZoned(
      () => env.controller.start(_password),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => logs.add(line),
      ),
    );

    expect(logs, isEmpty);
  });
}
