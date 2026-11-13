// TEMPORARY (fix/app-catalog-search-sheet-height only): screenshots of the
// catalog search sheet for the owner, before and after. Removed before the
// PR is handed over.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/app.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/routing/routes.dart';
import 'package:pillpal/src/settings/app_settings.dart';

import '../features/catalog_ui_env.dart';
import '../helpers.dart';
import '../support/narrow_layout.dart';

final String? _dir = Platform.environment['SHOTS_DIR'];
const double _ratio = 2;

const List<(String, Size, double, double)> _cells = [
  ('phone-411x914-x1.0', Size(411, 914), 1.0, 300),
  ('cover-280x653-x1.3', Size(280, 653), 1.3, 240),
];

List<Map<String, Object?>> _results() => [
      for (final (i, name, form) in const [
        (1, 'Аторвастатин-Тева', 'ТАБЛЕТКИ, ПОКРЫТЫЕ ПЛЕНОЧНОЙ ОБОЛОЧКОЙ'),
        (2, 'Аторвастатин Синтетический', 'КАПСУЛЫ'),
        (3, 'Синтетин', 'РАСТВОР ДЛЯ ИНЪЕКЦИЙ'),
        (4, 'Синтетин Офтальмо', 'КАПЛИ ГЛАЗНЫЕ'),
        (5, 'Синтетин Мазь', 'МАЗЬ'),
        (6, 'Синтетин Назал', 'СПРЕЙ НАЗАЛЬНЫЙ'),
        (7, 'Синтетин Порошок', 'ПОРОШОК'),
        (8, 'Синтетин Сироп', 'СИРОП'),
        (9, 'Синтетин Ректал', 'СУППОЗИТОРИИ'),
        (10, 'Synthetic Tablet', 'Oral Tablet'),
        (11, 'Синтетин Пластырь', 'ПЛАСТЫРЬ'),
      ])
        searchResultJson(
          id: 'ru-$i',
          name: name,
          form: form,
          substances: const ['Синтетическое вещество'],
        ),
    ];

Future<void> _shoot(WidgetTester tester, String name) async {
  final render = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(narrowShotKey),
  );
  await tester.runAsync(() async {
    final image = await render.toImage(pixelRatio: _ratio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File('$_dir/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadAppFonts);

  for (final (label, size, scale, keyboard) in _cells) {
    testWidgets('shots: $label', (tester) async {
      final env = CatalogUiEnv()..results = _results();
      final container = createContainer(env.harness, overrides: env.overrides);
      await env.harness.seedSelfProfile();
      container.read(settingsProvider.notifier).setLocale(const Locale('ru'));
      tester.view
        ..devicePixelRatio = _ratio
        ..physicalSize = size * _ratio
        ..viewInsets = FakeViewPadding(bottom: keyboard * _ratio);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(
            key: narrowShotKey,
            child: Stack(
              textDirection: TextDirection.ltr,
              children: [
                const PillPalApp(),
                // Where the keyboard would be.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: keyboard,
                  child: const ColoredBox(color: Color(0xFFB0B4BA)),
                ),
              ],
            ),
          ),
        ),
      );
      await settleNarrow(tester);
      goRoute(container, AppRoutes.newMedication);
      await settleNarrow(tester);
      await tester.ensureVisible(find.byKey(const Key('med-catalog')));
      await settleNarrow(tester);
      await tester.tap(find.byKey(const Key('med-catalog')));
      await settleNarrow(tester);
      await _shoot(tester, '$label-1-idle');

      final gate = env.searchGate = Completer<void>();
      await tester.enterText(
        find.byKey(const Key('catalog-search-text')),
        'синт',
      );
      await tester.pump(CatalogPolicy.searchDebounce);
      await tester.pump(const Duration(milliseconds: 200));
      await _shoot(tester, '$label-2-loading');

      gate.complete();
      await settleNarrow(tester);
      await _shoot(tester, '$label-3-loaded');

      final refine = env.searchGate = Completer<void>();
      await tester.enterText(
        find.byKey(const Key('catalog-search-text')),
        'синте',
      );
      await tester.pump(CatalogPolicy.searchDebounce);
      await tester.pump(const Duration(milliseconds: 200));
      await _shoot(tester, '$label-4-refining');
      refine.complete();
      await settleNarrow(tester);
      await tester.drag(
        find.byKey(const Key('catalog-results')),
        const Offset(0, -500),
      );
      await settleNarrow(tester);
      await _shoot(tester, '$label-5-loaded-scrolled');
    }, skip: _dir == null);
  }
}
