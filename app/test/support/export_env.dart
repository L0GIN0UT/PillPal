import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/auth/auth_session.dart';
import 'package:pillpal/src/features/privacy/export_controller.dart';
import 'package:pillpal/src/features/privacy/export_files.dart';
import 'package:pillpal/src/features/privacy/file_sharer.dart';

import '../helpers.dart';
import '../support/export_server.dart';

// The environment of the export controller tests: a signed-in account, the fake
// export server, a fake share sheet and instant waits.

const String exportUser = 'user-1';
const String exportPassword = 'correct-pass';

/// A signed-in account with the export screen open.
class ExportEnv {
  ExportEnv(this.server, this.harness, this.container, this.screen);

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
/// until [ExportEnv.screen] is closed.
Future<ExportEnv> exportEnv({
  FakeExportServer? server,
  ExportFiles? files,
}) async {
  final fake = server ?? FakeExportServer();
  final harness = TestHarness(handler: fake.handle);
  late final ExportEnv env;
  final container = createContainer(
    harness,
    overrides: [
      if (files != null) exportFilesProvider.overrideWithValue(files),
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
  await container.read(syncStateStoreProvider).bindAccount(exportUser, 'ru');
  expect(await container.read(authSessionProvider.future), isTrue);
  final screen = container.listen(exportControllerProvider, (_, __) {});
  addTearDown(screen.close);
  env = ExportEnv(fake, harness, container, screen);
  return env;
}

http.Response exportFailure(int status, String code) => http.Response(
      '{"error": {"code": "$code", "message": "synthetic"}}',
      status,
      headers: {'content-type': 'application/json'},
    );

