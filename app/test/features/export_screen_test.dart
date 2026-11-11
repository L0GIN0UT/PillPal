import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/privacy/export_controller.dart';
import 'package:pillpal/src/features/privacy/file_sharer.dart';
import 'package:pillpal/src/routing/router.dart';

import '../helpers.dart';
import '../support/export_server.dart';
import '../support/privacy_server.dart';

// The export screen (ADR 0016 §8): the password step-up, the wait, the
// download, the share sheet and what the user can do after a failure.

const String _password = 'correct-pass';

class _Env {
  _Env(this.server, this.harness, this.container);

  final FakePrivacyServer server;
  final TestHarness harness;
  final ProviderContainer container;
  ShareOutcome outcome = ShareOutcome.shared;
  int shares = 0;

  FakeExportServer get exports => server.exports;

  List<File> get filesOnDisk => harness.tempDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.contains('pillpal-export-'))
      .toList();
}

Future<_Env> _open(WidgetTester tester, {FakePrivacyServer? server}) async {
  final fake = server ?? FakePrivacyServer();
  final harness = TestHarness(handler: fake.handle);
  late final _Env env;
  final container = createContainer(
    harness,
    overrides: [
      exportDelayProvider.overrideWithValue((_) async {}),
      archiveSharerProvider.overrideWithValue((file) async {
        env.shares++;
        return env.outcome;
      }),
    ],
  );
  await container.read(syncStateStoreProvider).bindAccount('user-1', 'ru');
  await pumpApp(tester, harness: harness, container: container);
  openRoute(container, AppRoutes.dataExport);
  await tester.pumpAndSettle();
  env = _Env(fake, harness, container);
  return env;
}

/// Lets the real file IO of the export finish, which a widget test's fake
/// clock does not advance, until nothing is in progress any more.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 80; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      break;
    }
  }
  // Leaving the screen ends with a transition; deleting the file afterwards is
  // real IO too, and each of its steps needs a pump to continue.
  await tester.pumpAndSettle();
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<void> _tapAndSettle(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pump();
  await _settle(tester);
}

Future<void> _submit(
  WidgetTester tester, [
  String password = _password,
]) async {
  await tester.enterText(find.byKey(const Key('export-password')), password);
  await tester.pump();
  await _tapAndSettle(tester, 'export-submit');
}

String _field(WidgetTester tester) {
  final field = tester.widget<TextField>(
    find.byKey(const Key('export-password')),
  );
  return field.controller!.text;
}

void main() {
  testWidgets('shows the password step-up and what the archive is',
      (tester) async {
    await _open(tester);

    expect(find.byKey(const Key('export-password')), findsOneWidget);
    expect(find.byKey(const Key('export-submit')), findsOneWidget);
    expect(find.textContaining('never sent by e-mail'), findsOneWidget);
    expect(find.textContaining('within 24 hours'), findsOneWidget);
  });

  testWidgets('a good password runs the export to the share sheet and done',
      (tester) async {
    final env = await _open(tester);

    await _submit(tester);

    expect(env.shares, 1);
    expect(find.text('The archive was shared'), findsOneWidget);
    expect(
      env.filesOnDisk,
      hasLength(1),
      reason: 'kept until the screen is left',
    );
    expect(env.exports.calls, [
      'POST /v1/me/export',
      'GET /v1/me/export/$fakeExportId',
      'POST /v1/me/export/$fakeExportId/download',
    ]);

    await _tapAndSettle(tester, 'export-close');
    expect(find.byKey(const Key('export-close')), findsNothing);
    expect(env.filesOnDisk, isEmpty, reason: 'leaving deletes the archive');
  });

  testWidgets('a wrong password stays on the form, with the field cleared',
      (tester) async {
    final env = await _open(tester);

    await _submit(tester, 'wrong-pass');

    expect(find.text('Wrong password.'), findsOneWidget);
    expect(_field(tester), isEmpty);
    expect(env.exports.calls, ['POST /v1/me/export']);

    await _submit(tester);
    expect(find.text('The archive was shared'), findsOneWidget);
  });

  testWidgets('the cooldown says how long to wait', (tester) async {
    final server = FakePrivacyServer();
    server.exports
      ..requestFailure = (429, 'export_rate_limited')
      ..retryAfterSeconds = 1800;
    await _open(tester, server: server);

    await _submit(tester);

    expect(
      find.text(
        'An export was requested recently. Try again in 30 minutes.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('an archive that is too large cannot be asked for again',
      (tester) async {
    final server = FakePrivacyServer();
    server.exports
      ..status = 'failed'
      ..errorCode = 'export_too_large';
    await _open(tester, server: server);

    await _submit(tester);

    expect(find.text('The archive is too large to build.'), findsOneWidget);
    expect(find.byKey(const Key('export-restart')), findsNothing);
    expect(find.byKey(const Key('export-resume')), findsNothing);
    expect(find.byKey(const Key('export-close')), findsOneWidget);
  });

  testWidgets('a lost archive is requested again from the password step',
      (tester) async {
    final server = FakePrivacyServer();
    server.exports.breakAfterClaim = true;
    final env = await _open(tester, server: server);

    await _submit(tester);

    expect(
      find.text(
        'The archive was handed out but did not reach this phone. '
        'Request a new one.',
      ),
      findsOneWidget,
    );
    expect(env.exports.downloads, 1);
    await _tapAndSettle(tester, 'export-restart');
    expect(find.byKey(const Key('export-password')), findsOneWidget);
  });

  testWidgets('a transfer that broke before the claim can be checked again',
      (tester) async {
    final server = FakePrivacyServer();
    server.exports.breakBeforeClaim = true;
    final env = await _open(tester, server: server);

    await _submit(tester);
    expect(find.byKey(const Key('export-resume')), findsOneWidget);

    env.exports.breakBeforeClaim = false;
    await _tapAndSettle(tester, 'export-resume');

    expect(find.text('The archive was shared'), findsOneWidget);
  });

  testWidgets('a closed share sheet keeps the file, which leaving deletes',
      (tester) async {
    final env = await _open(tester);
    env.outcome = ShareOutcome.notShared;

    await _submit(tester);

    expect(find.text('Your archive is ready'), findsOneWidget);
    expect(env.filesOnDisk, hasLength(1));
    env.outcome = ShareOutcome.shared;
    await _tapAndSettle(tester, 'export-share');
    expect(find.text('The archive was shared'), findsOneWidget);
  });

  testWidgets('leaving the screen deletes an archive that was not shared',
      (tester) async {
    final env = await _open(tester);
    env.outcome = ShareOutcome.notShared;
    await _submit(tester);
    expect(env.filesOnDisk, hasLength(1));

    env.container.read(routerProvider).pop();
    await _settle(tester);

    expect(find.byKey(const Key('export-share')), findsNothing);
    expect(env.filesOnDisk, isEmpty);
  });

  testWidgets('the screen cannot be left while the archive is downloaded',
      (tester) async {
    final server = FakePrivacyServer();
    server.exports
      ..status = 'ready'
      ..holdDownload = Completer<void>();
    final env = await _open(tester, server: server);

    await tester.enterText(find.byKey(const Key('export-password')), _password);
    await tester.tap(find.byKey(const Key('export-submit')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(find.byKey(const Key('export-downloading')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(const Key('export-downloading')), findsOneWidget);

    server.exports.holdDownload!.complete();
    await _settle(tester);
    expect(find.text('The archive was shared'), findsOneWidget);
    expect(env.shares, 1);
  });

  testWidgets(
      'the typed password is cleared when the app goes to the '
      'background', (tester) async {
    await _open(tester);
    await tester.enterText(find.byKey(const Key('export-password')), _password);
    await tester.pump();
    expect(_field(tester), _password);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(_field(tester), _password, reason: 'inactive is not a background');
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();

    expect(_field(tester), isEmpty);
  });

  testWidgets('a refused request is shown and can be sent again',
      (tester) async {
    final server = FakePrivacyServer();
    server.exports.requestFailure = (503, 'rate_limit_unavailable');
    final env = await _open(tester, server: server);

    await _submit(tester);

    expect(find.byKey(const Key('export-error')), findsOneWidget);

    env.exports.requestFailure = null;
    await _submit(tester);
    expect(find.text('The archive was shared'), findsOneWidget);
  });
}
