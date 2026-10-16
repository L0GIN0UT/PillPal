import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/settings/app_settings.dart';

import 'helpers.dart';

void main() {
  testWidgets('Russian locale shows Russian labels', (tester) async {
    await pumpApp(tester, locale: const Locale('ru'));

    expect(find.text('Сегодня'), findsWidgets);
    expect(find.text('Лекарства'), findsOneWidget);
    expect(find.text('Близкие'), findsOneWidget);
    expect(find.text('История'), findsOneWidget);
  });

  testWidgets('switching language in settings relabels the app',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Русский'));
    await tester.pumpAndSettle();

    expect(find.text('Настройки'), findsOneWidget);
    expect(find.text('Крупный текст и кнопки'), findsOneWidget);
  });

  testWidgets('senior mode scales text', (tester) async {
    final container = await pumpApp(tester);
    final before = tester.getSize(find.text('Add medication')).height;

    container.read(settingsProvider.notifier).setSeniorMode(enabled: true);
    await tester.pumpAndSettle();

    final after = tester.getSize(find.text('Add medication')).height;
    expect(after, greaterThan(before));
  });

  testWidgets('dark theme is applied', (tester) async {
    final container = await pumpApp(tester);

    container.read(settingsProvider.notifier).setThemeMode(ThemeMode.dark);
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(NavigationBar));
    expect(Theme.of(context).brightness, Brightness.dark);
  });

  test('AppSettings equality and copyWith', () {
    const base = AppSettings();
    final ru = base.copyWith(locale: const Locale('ru'));
    expect(ru.locale, const Locale('ru'));
    expect(ru.copyWith(resetLocale: true), base);
    expect(base.copyWith(seniorMode: true) == base, isFalse);
  });
}
