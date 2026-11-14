import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/routing/routes.dart';
import 'package:pillpal/src/settings/app_settings.dart';

import '../helpers.dart';

// Settings -> Account -> «Ваше имя»: the person's own name (the `self`
// profile), which relatives see. Checked like at registration, written on the
// device and sent with the next sync.

Future<TestHarness> _openSettings(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  void Function(ProviderContainer container)? configure,
}) async {
  final harness = TestHarness();
  await harness.seedSelfProfile();
  final container = await pumpApp(tester, harness: harness, locale: locale);
  configure?.call(container);
  goRoute(container, AppRoutes.settings);
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _openRow(WidgetTester tester) async {
  final row = find.byKey(const Key('settings-own-name'));
  await tester.scrollUntilVisible(row, 200);
  await tester.tap(row);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the account card shows the name and renames you',
      (tester) async {
    final harness = await _openSettings(tester);
    final row = find.byKey(const Key('settings-own-name'));
    await tester.scrollUntilVisible(row, 200);
    expect(
      find.descendant(of: row, matching: find.text('Test User')),
      findsOneWidget,
    );

    await _openRow(tester);
    final field = find.byKey(const Key('own-name-field'));
    expect(tester.widget<TextField>(field).controller?.text, 'Test User');
    await tester.enterText(field, '  Мария  ');
    await tester.tap(find.byKey(const Key('own-name-save')));
    await tester.pumpAndSettle();

    // Back in Settings with the new name, written and queued for the sync.
    expect(find.byKey(const Key('own-name-field')), findsNothing);
    expect(
      find.descendant(of: row, matching: find.text('Мария')),
      findsOneWidget,
    );
    final outbox = await harness.db.select(harness.db.outbox).get();
    final payload = jsonDecode(outbox.single.payload!) as Map<String, Object?>;
    expect(payload['display_name'], 'Мария');
    expect(harness.syncCalls, greaterThan(0));
  });

  for (final name in ['A', '   ']) {
    testWidgets('a name outside the rule is explained (${jsonEncode(name)})',
        (tester) async {
      final harness = await _openSettings(tester, locale: const Locale('ru'));
      await _openRow(tester);
      await tester.enterText(find.byKey(const Key('own-name-field')), name);
      await tester.tap(find.byKey(const Key('own-name-save')));
      await tester.pumpAndSettle();

      expect(find.text('Имя должно быть от 2 до 20 символов.'), findsOneWidget);
      expect(find.byKey(const Key('own-name-field')), findsOneWidget);
      expect(await harness.db.select(harness.db.outbox).get(), isEmpty);
    });
  }

  testWidgets('the screen renders in dark theme and senior mode',
      (tester) async {
    await _openSettings(
      tester,
      locale: const Locale('ru'),
      configure: (container) {
        final settings = container.read(settingsProvider.notifier);
        settings.setThemeMode(ThemeMode.dark);
        settings.setSeniorMode(enabled: true);
      },
    );
    await _openRow(tester);

    expect(find.text('Ваше имя'), findsWidgets);
    expect(find.text('Это имя увидят ваши близкие'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
