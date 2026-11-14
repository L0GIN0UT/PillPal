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
  String? storedName,
  void Function(ProviderContainer container)? configure,
}) async {
  final harness = TestHarness();
  await harness.seedSelfProfile();
  if (storedName != null) {
    await harness.db.customStatement(
      'UPDATE profiles SET display_name = ?',
      [storedName],
    );
  }
  final container = await pumpApp(tester, harness: harness, locale: locale);
  configure?.call(container);
  goRoute(container, AppRoutes.settings);
  await tester.pumpAndSettle();
  return harness;
}

Finder get _row => find.byKey(const Key('settings-own-name'));
Finder get _field => find.byKey(const Key('own-name-field'));
Finder get _save => find.byKey(const Key('own-name-save'));

FilledButton _button(WidgetTester tester) => tester.widget<FilledButton>(
      find.descendant(of: _save, matching: find.byType(FilledButton)),
    );

Future<void> _openRow(WidgetTester tester) async {
  await tester.scrollUntilVisible(_row, 200);
  await tester.tap(_row);
  await tester.pumpAndSettle();
}

Future<List<Object?>> _outbox(TestHarness harness) async =>
    harness.db.select(harness.db.outbox).get();

void main() {
  testWidgets('the account card shows the name and renames you',
      (tester) async {
    final harness = await _openSettings(tester);
    await tester.scrollUntilVisible(_row, 200);
    expect(
      find.descendant(of: _row, matching: find.text('Test User')),
      findsOneWidget,
    );

    await _openRow(tester);
    expect(tester.widget<TextField>(_field).controller?.text, 'Test User');
    await tester.enterText(_field, '  Мария  ');
    await tester.tap(_save);
    await tester.pumpAndSettle();

    // Back in Settings with the new name, written and queued for the sync.
    expect(_field, findsNothing);
    expect(
      find.descendant(of: _row, matching: find.text('Мария')),
      findsOneWidget,
    );
    final outbox = await harness.db.select(harness.db.outbox).get();
    final payload = jsonDecode(outbox.single.payload!) as Map<String, Object?>;
    expect(payload['display_name'], 'Мария');
    expect(harness.syncCalls, greaterThan(0));
  });

  for (final name in ['A', '   ', '--']) {
    testWidgets('a name outside the rule is explained (${jsonEncode(name)})',
        (tester) async {
      final harness = await _openSettings(tester, locale: const Locale('ru'));
      await _openRow(tester);
      await tester.enterText(_field, name);
      await tester.tap(_save);
      await tester.pumpAndSettle();

      expect(find.text('2–20 символов, только видимые'), findsOneWidget);
      expect(_field, findsOneWidget);
      expect(await _outbox(harness), isEmpty);
    });
  }

  testWidgets('saving the same name just goes back', (tester) async {
    final harness = await _openSettings(tester);
    await _openRow(tester);
    await tester.enterText(_field, ' Test User ');
    await tester.tap(_save);
    await tester.pumpAndSettle();

    expect(_field, findsNothing);
    expect(await _outbox(harness), isEmpty);
  });

  testWidgets('the old default "Me" counts as no name yet', (tester) async {
    await _openSettings(
      tester,
      locale: const Locale('ru'),
      storedName: 'Me',
    );
    await tester.scrollUntilVisible(_row, 200);
    expect(
      find.descendant(of: _row, matching: find.text('Укажите имя')),
      findsOneWidget,
    );
    expect(find.descendant(of: _row, matching: find.text('Me')), findsNothing);

    await _openRow(tester);
    expect(tester.widget<TextField>(_field).controller?.text, isEmpty);
  });

  testWidgets('before the first pull the field waits for the profile',
      (tester) async {
    final harness = TestHarness();
    final container =
        await pumpApp(tester, harness: harness, locale: const Locale('ru'));
    goRoute(container, AppRoutes.ownName);
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(_field).enabled, isFalse);
    expect(_button(tester).onPressed, isNull);
    expect(find.text('Имя появится после синхронизации'), findsOneWidget);

    // The pull delivers the profile: the untouched field fills in.
    await harness.seedSelfProfile();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_field).enabled, isTrue);
    expect(tester.widget<TextField>(_field).controller?.text, 'Test User');
    expect(_button(tester).onPressed, isNotNull);
  });

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
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
