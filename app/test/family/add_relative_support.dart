import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/common/status_pill.dart';
import 'package:pillpal/src/links/link_providers.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'invite_server.dart';

// Shared steps of the «Добавить близкого» widget tests.

/// The app with «Добавить близкого» open over Today.
class AddRelativeRun {
  /// Creates the run.
  AddRelativeRun(this.harness, this.server, this.container, this.shared);

  /// The app environment (its clock is moved by the tests).
  final TestHarness harness;

  /// The fake invite endpoints.
  final FakeInviteServer server;

  /// The app's providers.
  final ProviderContainer container;

  /// What reached the share sheet.
  final List<String> shared;
}

/// Opens «Добавить близкого» against [server].
Future<AddRelativeRun> openAddRelative(
  WidgetTester tester, {
  FakeInviteServer? server,
}) async {
  final fake = server ?? FakeInviteServer();
  final harness = TestHarness(handler: fake.handle);
  final shared = <String>[];
  final container = createContainer(
    harness,
    overrides: [
      textSharerProvider.overrideWithValue((text) async => shared.add(text)),
    ],
  );
  await harness.seedSelfProfile();
  await pumpApp(tester, harness: harness, container: container);
  openRoute(container, AppRoutes.addRelative);
  await tester.pumpAndSettle();
  return AddRelativeRun(harness, fake, container, shared);
}

/// Taps [key] after scrolling to it.
Future<void> tapKey(WidgetTester tester, String key,
    {bool settle = true}) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// «Показать мой код» and the code it makes.
Future<void> showCode(WidgetTester tester) =>
    tapKey(tester, 'add-relative-show-code');

/// The text of the countdown pill.
String countdownText(WidgetTester tester) =>
    tester.widget<StatusPill>(find.byKey(const Key('invite-countdown'))).label!;

/// Whether the helper box takes taps.
bool roleBoxEnabled(WidgetTester tester) =>
    tester
        .widget<CheckboxListTile>(find.byKey(const Key('add-relative-editor')))
        .onChanged !=
    null;
