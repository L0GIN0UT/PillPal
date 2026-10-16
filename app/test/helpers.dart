import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/app.dart';
import 'package:pillpal/src/settings/app_settings.dart';

/// Pumps the whole app with a fresh [ProviderContainer] and [locale].
Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(settingsProvider.notifier).setLocale(locale);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const PillPalApp(),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}
