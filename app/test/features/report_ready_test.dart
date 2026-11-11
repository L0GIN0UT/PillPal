import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/report/report_actions.dart';
import 'package:pillpal/src/features/report/report_history.dart';
import 'package:pillpal/src/features/report/report_service.dart';

import '../helpers.dart';
import 'report_fakes.dart';

// The «Отчёт готов» state of the report sheet (board B2-ReportReady,
// docs/adr/0019 §5): what was made, the three file actions and what each
// result says. The actions are a fake; the report and its file are real.

Future<(ProviderContainer, FakeReportActions)> _openReadySheet(
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
  await tester.tap(find.byKey(const Key('report-create')));
  for (var i = 0;
      i < 50 && find.byKey(const Key('report-open')).evaluate().isEmpty;
      i++) {
    await settleReal(tester, rounds: 1);
  }
  await tester.pumpAndSettle();
  return (container, actions);
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
}
