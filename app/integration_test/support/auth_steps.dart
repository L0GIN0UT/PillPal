import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_driver.dart';
import 'host.dart';

/// Registers a new account through the welcome screen and verifies it with
/// the code from the backend log; returns once Today is shown.
Future<void> registerThroughUi(WidgetTester tester, HostControl host) async {
  await tapVisible(tester, find.byKey(const Key('welcome-register')));
  final email = 'emulator-${DateTime.now().microsecondsSinceEpoch}'
      '@example.com';
  await enterField(tester, const Key('auth-email'), email);
  await enterField(tester, const Key('auth-password'), 'emulator-password-1');
  final codesBefore = await host.codeCount();
  await tapVisible(tester, find.byKey(const Key('auth-submit')));
  await waitFor(tester, find.byKey(const Key('auth-code')));
  final code = await host.codeAfter(codesBefore);
  await enterField(tester, const Key('auth-code'), code);
  await tapVisible(tester, find.byKey(const Key('auth-submit')));
  await waitFor(tester, find.byType(NavigationBar), reason: 'Today');
}
