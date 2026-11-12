import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/report/report_actions.dart';
import 'package:pillpal/src/features/report/report_history.dart';
import 'package:pillpal/src/features/report/report_service.dart';
import 'package:pillpal/src/theme/motion.dart';

import '../helpers.dart';
import 'report_fakes.dart';

// The «Отчёт готов» state of the report sheet (board B2-ReportReady,
// docs/adr/0019 §5): what was made, the three file actions and what each
// result says. The actions are a fake; the report and its file are real.

Future<(ProviderContainer, FakeReportActions)> _openCreateSheet(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
}) async {
  final harness = TestHarness();
  final actions = FakeReportActions();
  final container = createContainer(
    harness,
    overrides: [
      reportActionsProvider.overrideWithValue(actions),
      reportRendererProvider.overrideWithValue(
        (report, l10n, locale) async =>
            Uint8List.fromList(List<int>.filled(2048, 1)),
      ),
    ],
  );
  await harness.seedSelfProfile();
  await pumpApp(tester, harness: harness, container: container, locale: locale);
  await tester.tap(find.byIcon(Icons.calendar_month_outlined));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('history-pdf')));
  await tester.pumpAndSettle();
  return (container, actions);
}

Future<(ProviderContainer, FakeReportActions)> _openReadySheet(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
}) async {
  final (container, actions) = await _openCreateSheet(tester, locale: locale);
  await tester.tap(find.byKey(const Key('report-create')));
  for (var i = 0;
      i < 50 && find.byKey(const Key('report-open')).evaluate().isEmpty;
      i++) {
    await settleReal(tester, rounds: 1);
  }
  await tester.pumpAndSettle();
  return (container, actions);
}

const _create = Key('report-create');
const _readyTitle = Key('report-ready-title');

/// Opacity of the nearest fade around [finder].
double _opacity(WidgetTester tester, Finder finder) => tester
    .widget<FadeTransition>(
      find.ancestor(of: finder, matching: find.byType(FadeTransition)).first,
    )
    .opacity
    .value;

double _sheetHeight(WidgetTester tester) =>
    tester.getSize(find.byType(BottomSheet)).height;

/// Taps «Создать» and lets the real work finish in small steps of the fake
/// clock; stops at the first frame in which the sheet started to change.
Future<void> _createUntilSwap(WidgetTester tester) async {
  await tester.tap(find.byKey(_create));
  for (var i = 0; i < 400; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 1));
    if (find.byKey(_readyTitle).evaluate().isNotEmpty ||
        find.byKey(_create).evaluate().isEmpty ||
        _opacity(tester, find.byKey(_create)) < 1) {
      return;
    }
  }
  fail('the sheet never started to swap');
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Create leads to the ready state with the three actions', (
    tester,
  ) async {
    await _openReadySheet(tester);

    expect(find.byKey(const Key('report-ready-title')), findsOneWidget);
    expect(find.text('Report ready'), findsOneWidget);
    expect(find.byKey(const Key('report-create')), findsNothing);
    for (final key in ['report-open', 'report-save', 'report-share']) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }
    // The period, whose report it is, the format and the size (2 KB), and
    // nothing from the report itself.
    expect(find.text('Sep 17, 2026 – Oct 16, 2026'), findsOneWidget);
    expect(find.text('Me · PDF · 2 KB'), findsOneWidget);
    expect(find.byKey(const Key('report-leaves-control')), findsOneWidget);
    expect(
      find.text("A saved or sent file is no longer under the app's control"),
      findsOneWidget,
    );
    expect(find.text('My reports (1)'), findsOneWidget);
    expect(find.byKey(const Key('report-notice')), findsNothing);
  });

  testWidgets('the sheet swaps its content: out, resize, then in', (
    tester,
  ) async {
    await _openCreateSheet(tester);
    final before = _sheetHeight(tester);

    await _createUntilSwap(tester);
    // First the old content fades out alone, at the old height.
    expect(find.byKey(_create), findsOneWidget);
    expect(find.byKey(_readyTitle), findsNothing);
    expect(_sheetHeight(tester), before);

    await tester.pump(PillPalMotion.fast);
    await tester.pump(PillPalMotion.base ~/ 4);
    // Then the new content fades in while the sheet takes its height.
    expect(find.byKey(_create), findsNothing);
    expect(_opacity(tester, find.byKey(_readyTitle)), inExclusiveRange(0, 1));
    final during = _sheetHeight(tester);

    await tester.pump(PillPalMotion.base);
    await tester.pump();
    final after = _sheetHeight(tester);
    expect(_opacity(tester, find.byKey(_readyTitle)), 1);
    expect(after, isNot(before), reason: 'the two states differ in height');
    expect(
      during,
      inExclusiveRange(
        before < after ? before : after,
        before < after ? after : before,
      ),
    );
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('reduced motion: the sheet swaps its content at once', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _openCreateSheet(tester);

    await _createUntilSwap(tester);

    expect(find.byKey(_readyTitle), findsOneWidget);
    expect(find.byKey(_create), findsNothing);
    expect(find.byType(AnimatedSize), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('the ready state is in Russian too', (tester) async {
    await _openReadySheet(tester, locale: const Locale('ru'));

    expect(find.text('Отчёт готов'), findsOneWidget);
    expect(find.text('Открыть'), findsOneWidget);
    expect(find.text('Сохранить'), findsOneWidget);
    expect(find.text('Поделиться'), findsOneWidget);
    expect(find.text('Мои отчёты (1)'), findsOneWidget);
    expect(find.text('Я · PDF · 2 КБ'), findsOneWidget);
  });

  testWidgets('Open, Save and Share act on the kept report', (tester) async {
    final (container, actions) = await _openReadySheet(tester);
    final kept = (await tester.runAsync(
      () => container.read(reportHistoryProvider).all(),
    ))!
        .single;

    await _tap(tester, 'report-open');
    // A silent success: nothing to say.
    expect(find.byKey(const Key('report-notice')), findsNothing);
    await _tap(tester, 'report-share');
    expect(find.byKey(const Key('report-notice')), findsNothing);
    await _tap(tester, 'report-save');

    expect(actions.calls, [
      'open:${kept.id}',
      'share:${kept.id}',
      'save:${kept.id}',
    ]);
    // A save says so; the sheet stays for the next action.
    expect(find.text('Report saved'), findsOneWidget);
    expect(find.byKey(const Key('report-open')), findsOneWidget);
  });

  testWidgets('no PDF viewer offers Save, which then saves', (tester) async {
    final (_, actions) = await _openReadySheet(tester);
    actions.results['open'] = ReportActionResult.noApp;

    await _tap(tester, 'report-open');
    expect(find.text('No app to view PDF'), findsOneWidget);

    await _tap(tester, 'report-notice-save');
    expect(actions.calls.map((c) => c.split(':').first), ['open', 'save']);
    expect(find.text('Report saved'), findsOneWidget);
    expect(find.text('No app to view PDF'), findsNothing);
  });

  testWidgets('a cancelled picker is silent', (tester) async {
    final (_, actions) = await _openReadySheet(tester);
    actions.results['save'] = ReportActionResult.cancelled;

    await _tap(tester, 'report-save');

    expect(actions.calls, hasLength(1));
    expect(find.byKey(const Key('report-notice')), findsNothing);
    expect(find.text('Report saved'), findsNothing);
  });

  testWidgets('busy and a failed file action are told, never detailed', (
    tester,
  ) async {
    final (_, actions) = await _openReadySheet(tester);
    actions.results['share'] = ReportActionResult.busy;

    await _tap(tester, 'report-share');
    expect(
      find.text(
        'Another action with a report is still in progress. '
        'Try again in a moment.',
      ),
      findsOneWidget,
    );

    actions.failure = StateError('io_error: /secret/path/report.pdf');
    await _tap(tester, 'report-open');
    expect(
      find.text('The report file could not be processed. Try again.'),
      findsOneWidget,
    );
    // The exception text never reaches the screen.
    expect(find.textContaining('secret'), findsNothing);
    expect(find.textContaining('io_error'), findsNothing);
  });

  testWidgets('My reports closes the sheet and opens the list', (tester) async {
    await _openReadySheet(tester);

    await _tap(tester, 'report-history');

    expect(find.byKey(const Key('report-ready-title')), findsNothing);
    expect(find.byKey(const Key('reports-list')), findsOneWidget);
  });

  testWidgets('a result shows above the buttons', (tester) async {
    final (_, actions) = await _openReadySheet(tester);
    actions.results['open'] = ReportActionResult.noApp;

    await _tap(tester, 'report-open');

    expect(
      tester.getTopLeft(find.byKey(const Key('report-notice'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('report-open'))).dy),
    );
  });
}
