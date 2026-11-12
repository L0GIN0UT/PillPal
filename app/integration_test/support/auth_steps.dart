import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'app_driver.dart';
import 'host.dart';

/// Registers a new account through the welcome screen (credentials, the three
/// consents, then the code from the backend log); returns once Today is shown.
Future<void> registerThroughUi(WidgetTester tester, HostControl host) async {
  await tapVisible(tester, find.byKey(const Key('welcome-register')));
  final email = 'emulator-${DateTime.now().microsecondsSinceEpoch}'
      '@example.com';
  await enterField(tester, const Key('auth-email'), email);
  await enterField(tester, const Key('auth-password'), 'emulator-password-1');
  await tapVisible(tester, find.byKey(const Key('auth-submit')));
  await waitFor(tester, find.byKey(const Key('consent-submit')));
  for (final key in ['consent-terms', 'consent-privacy', 'consent-health']) {
    await tapVisible(tester, find.byKey(Key(key)));
  }
  // The request, and so the mail, is sent by «Create account».
  final codesBefore = await host.codeCount();
  await tapVisible(tester, find.byKey(const Key('consent-submit')));
  await waitFor(tester, find.byKey(const Key('auth-code')));
  final code = await host.codeAfter(codesBefore);
  await enterField(tester, const Key('auth-code'), code);
  await tapVisible(tester, find.byKey(const Key('auth-submit')));
  await waitFor(tester, find.byType(NavigationBar), reason: 'Today');
}
