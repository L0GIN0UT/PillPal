import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/report/report_actions.dart';
import 'package:pillpal/src/features/report/report_history.dart';
import 'package:pillpal/src/routing/router.dart';
import 'package:pillpal/src/theme/motion.dart';

import '../helpers.dart';
import 'report_fakes.dart';

// «Мои отчёты» (board B2-MyReports, docs/adr/0019): the kept reports, newest
// first, with a menu per row and «Удалить все». The history is real (files in
// the harness's temp folder, rows in drift); the file actions are a fake.

class _Env {
  _Env(this.harness, this.container, this.actions);

  final TestHarness harness;
  final ProviderContainer container;
  final FakeReportActions actions;
}

_Env _env() {
  final harness = TestHarness();
  final actions = FakeReportActions();
  final container = createContainer(
    harness,
    overrides: [reportActionsProvider.overrideWithValue(actions)],
  );
  return _Env(harness, container, actions);
}

Future<void> _openList(
  WidgetTester tester,
  _Env env, {
  Locale locale = const Locale('en'),
}) async {
  await pumpApp(
    tester,
    harness: env.harness,
    container: env.container,
    locale: locale,
  );
  openRoute(env.container, AppRoutes.reports);
  await settleReal(tester);
  await tester.pumpAndSettle();
}

Future<void> _openMenu(WidgetTester tester, StoredReport report) async {
  await tester.tap(find.byKey(ValueKey('report-item-menu-${report.id}')));
  await tester.pumpAndSettle();
}

Finder _row(StoredReport report) =>
    find.byKey(ValueKey('report-item-${report.id}'));

/// Opacity of the fade a row leaves with (1 while it stays).
double _rowOpacity(WidgetTester tester, StoredReport report) => tester
    .widget<FadeTransition>(
      find
          .ancestor(of: _row(report), matching: find.byType(FadeTransition))
          .first,
    )
    .opacity
    .value;

/// Lets the real delete finish in small steps of the fake clock and stops at
/// the first frame in which the row of [report] is leaving or gone.
Future<void> _untilLeaving(WidgetTester tester, StoredReport report) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 1));
    if (_row(report).evaluate().isEmpty || _rowOpacity(tester, report) < 1) {
      return;
    }
  }
  fail('the row never started to leave');
}

void main() {
  testWidgets('empty: a note, no delete-all', (tester) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    await _openList(tester, env);

    expect(find.text('My reports'), findsOneWidget);
    expect(find.byKey(const Key('reports-empty')), findsOneWidget);
    expect(find.text('No reports yet'), findsOneWidget);
    expect(
      find.text(
        'Reports you make in History are kept on this phone for 90 '
        'days.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('reports-list')), findsNothing);
    expect(find.byKey(const Key('reports-delete-all')), findsNothing);
  });

  testWidgets('rows, newest first, show the period, profile, date and size', (
    tester,
  ) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    final older = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 10,
      createdAt: DateTime.utc(2026, 10, 11, 8),
    );
    final newer = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 14,
      createdAt: DateTime.utc(2026, 10, 15, 8),
    );
    await _openList(tester, env);

    expect(find.byKey(const Key('reports-empty')), findsNothing);
    final newerRow = find.byKey(ValueKey('report-item-${newer.id}'));
    final olderRow = find.byKey(ValueKey('report-item-${older.id}'));
    expect(newerRow, findsOneWidget);
    expect(olderRow, findsOneWidget);
    expect(
      tester.getTopLeft(newerRow).dy,
      lessThan(tester.getTopLeft(olderRow).dy),
    );
    expect(
      find.descendant(
        of: newerRow,
        matching: find.text('Oct 14, 2026 – Oct 14, 2026'),
      ),
      findsOneWidget,
    );
    // "Me", when it was made (device zone, so only the shape is checked) and
    // the size (2 KB).
    expect(
      find.descendant(
        of: newerRow,
        matching: find.textContaining(
          RegExp(r'^Me · Oct \d+ \d\d:\d\d · 2 KB$'),
        ),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('reports-delete-all')), findsOneWidget);
    expect(
      find.byKey(ValueKey('report-item-menu-${newer.id}')),
      findsOneWidget,
    );
  });

  testWidgets('a row opens its report', (tester) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    final report = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 10,
    );
    await _openList(tester, env);

    await tester.tap(find.byKey(ValueKey('report-item-${report.id}')));
    await tester.pumpAndSettle();

    expect(env.actions.calls, ['open:${report.id}']);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the menu opens, saves, shares and deletes', (tester) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    final report = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 10,
    );
    await _openList(tester, env);

    for (final item in ['open', 'save']) {
      await _openMenu(tester, report);
      await tester.tap(find.byKey(Key('report-menu-$item')));
      await tester.pumpAndSettle();
    }
    // A saved copy is confirmed.
    expect(find.text('Report saved'), findsOneWidget);
    await _openMenu(tester, report);
    await tester.tap(find.byKey(const Key('report-menu-share')));
    await tester.pumpAndSettle();
    expect(env.actions.calls, [
      'open:${report.id}',
      'save:${report.id}',
      'share:${report.id}',
    ]);

    // Delete: the row and the file go, without a dialog.
    await _openMenu(tester, report);
    await tester.tap(find.byKey(const Key('report-menu-delete')));
    await settleReal(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('report-item-${report.id}')), findsNothing);
    expect(find.byKey(const Key('reports-empty')), findsOneWidget);
    expect(await fileExists(tester, env.container, report), isFalse);
  });

  testWidgets('deleting one keeps the others', (tester) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    final first = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 10,
    );
    final second = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 11,
    );
    await _openList(tester, env);

    await _openMenu(tester, first);
    await tester.tap(find.byKey(const Key('report-menu-delete')));
    await settleReal(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('report-item-${first.id}')), findsNothing);
    expect(find.byKey(ValueKey('report-item-${second.id}')), findsOneWidget);
    expect(await fileExists(tester, env.container, second), isTrue);
  });

  testWidgets('the last report fades out before the empty note comes', (
    tester,
  ) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    final report = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 10,
    );
    await _openList(tester, env);

    await _openMenu(tester, report);
    await tester.tap(find.byKey(const Key('report-menu-delete')));
    await _untilLeaving(tester, report);

    expect(_row(report), findsOneWidget, reason: 'still leaving');
    expect(_rowOpacity(tester, report), lessThan(1));
    expect(find.byKey(const Key('reports-empty')), findsNothing);
    // «Удалить все» has nothing left to delete.
    expect(find.byKey(const Key('reports-delete-all')), findsNothing);

    await tester.pumpAndSettle();
    expect(_row(report), findsNothing);
    expect(find.byKey(const Key('reports-empty')), findsOneWidget);
  });

  testWidgets('delete all: the rows leave one after another', (tester) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    final reports = [
      for (final day in [10, 11])
        await keepReport(
          tester,
          env.container,
          profileId: selfProfileId,
          day: day,
        ),
    ];
    await _openList(tester, env);
    // In the order of the screen, whatever the order they were made in.
    reports.sort(
      (a, b) => tester
          .getTopLeft(_row(a))
          .dy
          .compareTo(tester.getTopLeft(_row(b)).dy),
    );
    final [top, bottom] = reports;

    await tester.tap(find.byKey(const Key('reports-delete-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-yes')));
    await _untilLeaving(tester, top);

    expect(_rowOpacity(tester, top), lessThan(1));
    expect(_rowOpacity(tester, bottom), 1, reason: 'one step later');
    expect(find.byKey(const Key('reports-empty')), findsNothing);

    await tester.pump(PillPalMotion.stagger);
    expect(_rowOpacity(tester, bottom), lessThan(1));

    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reports-empty')), findsOneWidget);
  });

  testWidgets('reduced motion: a deleted report is gone at once', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final env = _env();
    await env.harness.seedSelfProfile();
    final report = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 10,
    );
    await _openList(tester, env);

    await _openMenu(tester, report);
    await tester.tap(find.byKey(const Key('report-menu-delete')));
    await _untilLeaving(tester, report);

    expect(_row(report), findsNothing);
    expect(find.byKey(const Key('reports-empty')), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('delete all asks first; cancel keeps, confirm deletes', (
    tester,
  ) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    final first = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 10,
    );
    final second = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 11,
    );
    await _openList(tester, env);

    await tester.tap(find.byKey(const Key('reports-delete-all')));
    await tester.pumpAndSettle();
    expect(find.text('Delete all reports?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-no')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('report-item-${first.id}')), findsOneWidget);

    await tester.tap(find.byKey(const Key('reports-delete-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-yes')));
    await settleReal(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('reports-empty')), findsOneWidget);
    expect(find.byKey(const Key('reports-delete-all')), findsNothing);
    expect(await fileExists(tester, env.container, first), isFalse);
    expect(await fileExists(tester, env.container, second), isFalse);
  });

  testWidgets('opening the screen reconciles: a row without a file goes', (
    tester,
  ) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    final lost = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 10,
    );
    final kept = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 11,
    );
    final file = await tester.runAsync(
      () => env.container.read(reportHistoryProvider).fileOf(lost),
    );
    await tester.runAsync(() => file!.delete());
    await _openList(tester, env);

    expect(find.byKey(ValueKey('report-item-${lost.id}')), findsNothing);
    expect(find.byKey(ValueKey('report-item-${kept.id}')), findsOneWidget);
  });

  testWidgets('no PDF viewer: a snack bar offers Save, which saves', (
    tester,
  ) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    final report = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 10,
    );
    await _openList(tester, env);
    env.actions.results['open'] = ReportActionResult.noApp;

    await tester.tap(find.byKey(ValueKey('report-item-${report.id}')));
    await tester.pumpAndSettle();
    expect(find.text('No app to view PDF'), findsOneWidget);

    await tester.tap(
      find.descendant(of: find.byType(SnackBar), matching: find.text('Save')),
    );
    await tester.pumpAndSettle();
    expect(env.actions.calls, ['open:${report.id}', 'save:${report.id}']);
  });

  testWidgets('busy, failure and a cancelled picker', (tester) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    final report = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 10,
    );
    await _openList(tester, env);

    env.actions.results['share'] = ReportActionResult.busy;
    await _openMenu(tester, report);
    await tester.tap(find.byKey(const Key('report-menu-share')));
    await tester.pumpAndSettle();
    expect(find.textContaining('still in progress'), findsOneWidget);

    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold).first),
    ).clearSnackBars();
    await tester.pumpAndSettle();
    env.actions.failure = StateError('io_error');
    await _openMenu(tester, report);
    await tester.tap(find.byKey(const Key('report-menu-open')));
    await tester.pumpAndSettle();
    expect(
      find.text('The report file could not be processed. Try again.'),
      findsOneWidget,
    );

    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold).first),
    ).clearSnackBars();
    await tester.pumpAndSettle();
    env.actions.failure = null;
    env.actions.results['save'] = ReportActionResult.cancelled;
    await _openMenu(tester, report);
    await tester.tap(find.byKey(const Key('report-menu-save')));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the relative is named in the row', (tester) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    const relativeId = '00000000-0000-4000-8000-0000000000aa';
    await env.harness.db.into(env.harness.db.profiles).insert(
          const ProfileRow(
            id: relativeId,
            kind: 'self',
            displayName: 'Test Relative',
            timezone: testZone,
            clientUpdatedAt: 1,
            updatedByDevice: 'test-device',
            missedAlertMinutes: 30,
            missedAlertsEnabled: true,
          ),
        );
    await env.harness.db.into(env.harness.db.accessScopes).insert(
          AccessScopesCompanion.insert(
            profileId: relativeId,
            role: ScopeRole.viewer,
            kind: 'self',
          ),
        );
    final report = await keepReport(
      tester,
      env.container,
      profileId: relativeId,
      day: 10,
    );
    await _openList(tester, env);

    expect(
      find.descendant(
        of: find.byKey(ValueKey('report-item-${report.id}')),
        matching: find.textContaining('Test Relative · '),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the list is in Russian', (tester) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    final report = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 10,
    );
    await _openList(tester, env, locale: const Locale('ru'));

    expect(find.text('Мои отчёты'), findsOneWidget);
    expect(find.text('Удалить все'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(ValueKey('report-item-${report.id}')),
        matching: find.textContaining(RegExp(r'^Я · .* · 2 КБ$')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a deleted report is confirmed in a snack bar', (tester) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    final report = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 10,
    );
    await _openList(tester, env);

    await _openMenu(tester, report);
    await tester.tap(find.byKey(const Key('report-menu-delete')));
    await settleReal(tester);
    await tester.pumpAndSettle();

    expect(find.text('Report deleted'), findsOneWidget);
  });

  testWidgets('leaving the screen drops the snack bar and its Save action',
      (tester) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    final report = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 10,
    );
    await _openList(tester, env);
    env.actions.results['open'] = ReportActionResult.noApp;
    await tester.tap(find.byKey(ValueKey('report-item-${report.id}')));
    await tester.pumpAndSettle();
    final action =
        tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed;

    env.container.read(routerProvider).pop();
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);

    // A stale tap on the action does nothing and does not throw.
    action();
    await tester.pumpAndSettle();
    expect(env.actions.calls, ['open:${report.id}']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the row menu is its own node, apart from the row',
      (tester) async {
    final env = _env();
    await env.harness.seedSelfProfile();
    final report = await keepReport(
      tester,
      env.container,
      profileId: selfProfileId,
      day: 10,
    );
    await _openList(tester, env);
    final semantics = tester.ensureSemantics();
    await tester.pump();

    final menu = tester.getSemantics(
      find.descendant(
        of: find.byKey(ValueKey('report-item-menu-${report.id}')),
        matching: find.byType(IconButton),
      ),
    );
    final data = menu.getSemanticsData();
    expect(data.tooltip, contains('More:'));
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    // Not merged with the row's period and meta.
    expect(data.label, isNot(contains('2026')));
    final row = tester
        .getSemantics(find.text('Oct 10, 2026 – Oct 10, 2026'))
        .getSemanticsData();
    expect(row.label, contains('2026'));
    expect(row.tooltip, isNot(contains('More:')));
    semantics.dispose();
  });
}
